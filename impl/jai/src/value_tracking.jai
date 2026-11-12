// ValueTracking, part 1: computeKnownBits, isKnownToBeAPowerOfTwo, isKnownNonZero.
// A port of llvm/lib/Analysis/ValueTracking.cpp (computeKnownBits and helpers, computeKnownBitsFromContext,
// computeKnownBitsFromCmp/Cond, getKnownBitsFromAndXorOr, adjustKnownBitsForSelectArm, isKnownToBeAPowerOfTwo,
// isKnownNonZero and helpers, isKnownNonNullFromDominatingCondition) and llvm/lib/IR/Value.cpp
// (getPointerAlignment). The rest of ValueTracking is in value_tracking2.jai (sign bits, non-equality, ranges,
// implied conditions, poison/undef) and fpclass.jai (computeKnownFPClass).
//
// Differences from LLVM's interface: results are returned (no out-parameters); DemandedElts is an APInt as in LLVM
// (width = element count of a fixed vector, else 1). There is no DomConditionCache or CondContext yet (InstSimplify
// passes neither); they are InstCombine's.

DOM_CONDITIONS_MAX_USES :: 20;   // -dom-conditions-max-uses

// getBitWidth(Ty, DL)
vt_bit_width :: inline (t: Type_Id) -> u32 {
    st := scalar_type(t);
    b := type_bits(st);
    if b != 0 return b;
    if type_kind(st) == .PTR return dl_ptr_spec(cast(u32) ir.types[st].a).bits;
    return 0;
}
// DL.getIndexTypeSizeInBits
dl_index_bits :: (t: Type_Id) -> u32 { return dl_ptr_spec(cast(u32) ir.types[scalar_type(t)].a).idx_bits; }
// demanded elements of "all lanes" (FixedVectorType: all ones of the element count; scalars and scalable: 1)
dem_all :: (t: Type_Id) -> APInt {
    if type_kind(t) == .VECTOR return ap_all_ones(cast(u32) type_count(t));
    return ap_one(1);
}
// kept for older callers (DemandedBits, BDCE)
kb_scalar_bits :: (t: Type_Id) -> u32 { return vt_bit_width(t); }

// ---------------------------------------------------------------- entry points

known_bits :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> Known_Bits {
    return known_bits_de(v, dem_all(vtype(v)), q, depth);
}
// computeKnownBits(V, DL, AC, CxtI, DT, UseInstrInfo, Depth)
known_bits_ctx :: (v: Value_Id, cxt: Value_Id, dt: *Dom_Tree, ac: *Assumption_Cache, depth: u32 = 0) -> Known_Bits {
    q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = safe_cxt(v, cxt);
    return known_bits(v, q, depth);
}
// MaskedValueIsZero
masked_value_is_zero :: (v: Value_Id, mask: APInt, q: Simplify_Query, depth: u32 = 0) -> bool {
    k := known_bits(v, q, depth);
    return ap_is_subset_of(mask, k.zero);
}
is_known_non_negative :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool { return kb_is_non_negative(known_bits(v, q, depth)); }
is_known_negative :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool { return kb_is_negative(known_bits(v, q, depth)); }
is_known_positive :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool {
    if is_scalar_const_int(v) return ap_is_strictly_positive(const_ap(v));
    k := known_bits(v, q, depth);
    return kb_is_non_negative(k) && (kb_is_non_zero(k) || is_known_non_zero(v, q, depth));
}

// computeKnownBits(const Value *V, const APInt &DemandedElts, KnownBits &Known, const SimplifyQuery &Q, unsigned Depth)
known_bits_de :: (v: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> Known_Bits {
    bits := vt_bit_width(vtype(v));
    known := kb_new(bits);
    if ap_is_zero(de) return known;
    assert(depth <= MAX_ANALYSIS_RECURSION_DEPTH);
    ok, c := pm_apint(v);
    if ok return kb_from_const(c);
    k := vkind(v);
    if k == .C_NULL || k == .C_ZERO { kb_set_all_zero(*known); return known; }
    if k == .C_DATA {
        if !is_int_type(scalar_type(vtype(v))) { return known; }   // (ConstantDataVector of FP: no ConstantInt elements)
        kb_set_all_conflict(*known);
        n := const_data_count(v);
        for e: 0..cast(s64) n - 1 {
            if !ap_get_bit(de, cast(u32) e) continue;
            elt := ap_from_u64(bits, const_data_elt(v, cast(u64) e));
            known.zero = ap_and(known.zero, ap_not(elt));
            known.one = ap_and(known.one, elt);
        }
        if kb_has_conflict(known) kb_reset_all(*known);
        return known;
    }
    if k == .C_VECTOR {
        kb_set_all_conflict(*known);
        n := nops(v);
        for e: 0..cast(s64) n - 1 {
            if !ap_get_bit(de, cast(u32) e) continue;
            elt := op(v, cast(u32) e);
            if vkind(elt) == .C_POISON continue;
            if vkind(elt) != .C_INT { kb_reset_all(*known); return known; }
            a := const_ap(elt);
            known.zero = ap_and(known.zero, ap_not(a));
            known.one = ap_and(known.one, a);
        }
        if kb_has_conflict(known) kb_reset_all(*known);
        return known;
    }
    kb_reset_all(*known);
    if k == .C_UNDEF || k == .C_POISON return known;
    if k == .ARGUMENT {
        okr, r := arg_range(v);
        if okr known = cr_to_known_bits(r);
    }
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return known;
    if k == .ALIAS {
        if !gv_is_interposable(v) known = known_bits(op(v, 0), q, depth + 1);
        return known;
    }
    if k == .INST || k == .C_EXPR {
        known = kb_from_operator(v, de, known, q, depth);
    } else if is_global_value(k) {
        if get_metadata(v, md_kind_id("absolute_symbol")) != NONE fatal("known bits of an !absolute_symbol global are not supported yet");
    }
    if is_ptr_type(vtype(v)) {
        a := pointer_alignment(v);
        ap_set_low_bits(*known.zero, log2_u64(a));
    }
    known_bits_from_context(v, *known, q, depth);
    return known;
}
log2_u64 :: (x: u64) -> u32 { return 63 - clz64(x); }

// Value::getPointerAlignment
pointer_alignment :: (v: Value_Id) -> u64 {
    k := vkind(v);
    if k == .FUNCTION {
        return 1;
    }
    if k == .GLOBAL_VAR {
        g := glob(v);
        if g.align == 0 {
            t := g.value_type;
            if type_is_sized(t) {
                if gv_is_strong_definition_for_linker(v) return dl_preferred_align_gv(v);
                return dl_abi_align(t);
            }
        }
        return max(g.align, 1);
    }
    if k == .ARGUMENT {
        s := arg_attrs(v);
        a := attr_set_find(s, .Alignment);
        if !a {
            sr := attr_set_find(s, .StructRet);
            if sr && sr.ty != NONE && type_is_sized(sr.ty) return dl_abi_align(sr.ty);
            return 1;
        }
        return a.ival;
    }
    if k == .INST {
        o := inst_op(v);
        if o == .ALLOCA return inst(v).align;
        if o == .CALL || o == .INVOKE || o == .CALLBR {
            a := attr_set_find(attr_list_ret(inst(v).attrs), .Alignment);
            if !a {
                f := call_called_function(v);
                if f != NONE a = attr_set_find(attr_list_ret(glob(f).attrs), .Alignment);
            }
            if a return a.ival;
            return 1;
        }
        if o == .LOAD {
            m := inst_md(v, "align");
            if m != NONE return ap_limited(const_ap(ir.mds[md_op(m, 0)].value));
        }
        return 1;
    }
    if k == .C_EXPR {
        if cexpr(v).op == .INTTOPTR && is_scalar_const_int(op(v, 0)) {
            tz := ap_ctz(const_ap(op(v, 0)));
            if tz < 32 return (cast(u64) 1) << tz;   // Value::MaxAlignmentExponent = 32
            return (cast(u64) 1) << 32;
        }
    }
    return 1;
}
// GlobalValue::isStrongDefinitionForLinker
gv_is_strong_definition_for_linker :: (g: Value_Id) -> bool {
    if is_declaration(g) return false;
    l := glob(g).linkage;
    if l == .AVAILABLE_EXTERNALLY return false;
    // isWeakForLinker
    if l == .WEAK_ANY || l == .WEAK_ODR || l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .COMMON || l == .EXTERN_WEAK return false;
    return true;
}
// DataLayout::getPreferredAlign(const GlobalVariable *)
dl_preferred_align_gv :: (g: Value_Id) -> u64 {
    gr := glob(g);
    if gr.align != 0 && gr.section.count > 0 return gr.align;
    t := gr.value_type;
    a := dl_pref_align(t);
    if gr.align != 0 {
        if gr.align >= a a = gr.align;
        else a = max(gr.align, dl_abi_align(t));
    }
    if gr.has_init && gr.align == 0 {
        if a < 16 && dl_type_size_bits(t) > 128 a = 16;
    }
    return a;
}

// ---------------------------------------------------------------- computeKnownBitsFromOperator

kb_from_operator :: (i: Value_Id, de: APInt, known_in: Known_Bits, q: Simplify_Query, depth: u32) -> Known_Bits {
    known := known_in;
    bits := kb_bits(known);
    opc := opr_code(i);
    if opc == {
        case .LOAD;
            md := iiq_metadata(q, i, "range");
            if md != NONE known = kb_from_range_metadata(md, bits);
        case .AND; #through;
        case .OR; #through;
        case .XOR;
            k1 := known_bits_de(op(i, 1), de, q, depth + 1);
            k2 := known_bits_de(op(i, 0), de, q, depth + 1);
            known = known_bits_and_xor_or(i, de, k2, k1, q, depth);
        case .MUL;
            known = known_bits_mul(op(i, 0), op(i, 1), iiq_nsw(q, i), iiq_nuw(q, i), de, q, depth);
        case .UDIV;
            k1 := known_bits_de(op(i, 0), de, q, depth + 1);
            k2 := known_bits_de(op(i, 1), de, q, depth + 1);
            known = kb_udiv(k1, k2, iiq_exact(q, i));
        case .SDIV;
            k1 := known_bits_de(op(i, 0), de, q, depth + 1);
            k2 := known_bits_de(op(i, 1), de, q, depth + 1);
            known = kb_sdiv(k1, k2, iiq_exact(q, i));
        case .SELECT;
            compute_for_arm :: (i: Value_Id, arm: Value_Id, invert: bool, de: APInt, q: Simplify_Query, depth: u32) -> Known_Bits {
                res := known_bits_de(arm, de, q, depth + 1);
                adjust_known_bits_for_select_arm(*res, op(i, 0), arm, invert, q, depth);
                return res;
            }
            known = kb_intersect(compute_for_arm(i, op(i, 1), false, de, q, depth), compute_for_arm(i, op(i, 2), true, de, q, depth));
        case .FPTRUNC; #through; case .FPEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .SITOFP; #through; case .UITOFP;
            // can't work with floating point
        case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through;
        case .ZEXT; #through; case .TRUNC;
            src := vtype(op(i, 0));
            st := scalar_type(src);
            src_bits := ifx is_ptr_type(st) then dl_ptr_spec(cast(u32) ir.types[st].a).bits else cast(u32) dl_type_size_bits(st);
            k := known_bits_de(op(i, 0), de, q, depth + 1);
            assert(kb_bits(k) == src_bits);
            if (opc == .ZEXT || opc == .UITOFP) && (opr_flags(i) & F_EXACT) != 0 && !kb_is_negative(k) kb_make_non_negative(*k);
            known = kb_zext_or_trunc(k, bits);
        case .BITCAST;
            known = known_bits_bitcast(i, de, known, q, depth);
        case .SEXT;
            k := known_bits_de(op(i, 0), de, q, depth + 1);
            known = kb_sext(k, bits);
        case .SHL;
            nuw := iiq_nuw(q, i); nsw := iiq_nsw(q, i);
            k2, kamt, nz := known_bits_shift_operands(i, de, q, depth);
            known = kb_shl(k2, kamt, nuw, nsw, nz);
            okc, c := pm_apint(op(i, 0));
            if okc ap_set_low_bits(*known.zero, ap_ctz(c));
            // (shl X, (sub YC, (xor (ctlz X, true), BW-1)))
            if is_power_of_2_u32(bits) {
                okd, yc_v, x2 := pm_binop(op(i, 1), .SUB);
                if okd {
                    oky, yc := pm_apint(yc_v);
                    okx, xa, xb := pm_binop(x2, .XOR);
                    if oky && okx {
                        ctlz := xa; bw1 := xb;
                        if !(call_iid(ctlz) == IID_CTLZ && op(ctlz, 0) == op(i, 0) && pm_one(op(ctlz, 1)) && pm_specific_int(bw1, bits - 1)) {
                            ctlz = xb; bw1 = xa;
                        }
                        if call_iid(ctlz) == IID_CTLZ && op(ctlz, 0) == op(i, 0) && pm_one(op(ctlz, 1)) && pm_specific_int(bw1, bits - 1) && ap_ult_u64(yc, bits - 1) {
                            y := cast(u32) ap_zext_value(yc);
                            ap_set_bit(*known.one, y);
                            ap_set_bits_from(*known.zero, y + 1);
                        }
                    }
                }
            }
        case .LSHR;
            exact := iiq_exact(q, i);
            k2, kamt, nz := known_bits_shift_operands(i, de, q, depth);
            known = kb_lshr(k2, kamt, nz, exact);
            okc, c := pm_apint(op(i, 0));
            if okc ap_set_high_bits(*known.zero, ap_clz(c));
        case .ASHR;
            exact := iiq_exact(q, i);
            k2, kamt, nz := known_bits_shift_operands(i, de, q, depth);
            known = kb_ashr(k2, kamt, nz, exact);
        case .SUB;
            known = known_bits_add_sub(false, op(i, 0), op(i, 1), iiq_nsw(q, i), iiq_nuw(q, i), de, q, depth);
        case .ADD;
            known = known_bits_add_sub(true, op(i, 0), op(i, 1), iiq_nsw(q, i), iiq_nuw(q, i), de, q, depth);
        case .SREM;
            k1 := known_bits_de(op(i, 0), de, q, depth + 1);
            k2 := known_bits_de(op(i, 1), de, q, depth + 1);
            known = kb_srem(k1, k2);
        case .UREM;
            k1 := known_bits_de(op(i, 0), de, q, depth + 1);
            k2 := known_bits_de(op(i, 1), de, q, depth + 1);
            known = kb_urem(k1, k2);
        case .ALLOCA;
            ap_set_low_bits(*known.zero, log2_u64(inst(i).align));
        case .GEP;
            known = known_bits_gep(i, bits, q, depth);
        case .PHI;
            known = known_bits_phi(i, de, bits, q, depth);
        case .CALL; #through;
        case .INVOKE;
            known = known_bits_call(i, de, known, q, depth);
        case .SHUFFLEVECTOR;
            known = known_bits_shuffle(i, de, known, q, depth);
        case .INSERTELEMENT;
            if type_kind(vtype(i)) == .SVECTOR { kb_reset_all(*known); return known; }
            vec := op(i, 0); elt := op(i, 1); cidx := op(i, 2);
            n := de.bits;
            dve := ap_copy(de);
            needs_elt := true;
            if is_scalar_const_int(cidx) && ap_ult_u64(const_ap(cidx), n) {
                ix := cast(u32) ap_zext_value(const_ap(cidx));
                ap_clear_bit(*dve, ix);
                needs_elt = ap_get_bit(de, ix);
            }
            kb_set_all_conflict(*known);
            if needs_elt {
                known = known_bits(elt, q, depth + 1);
                if kb_is_unknown(known) return known;
            }
            if !ap_is_zero(dve) known = kb_intersect(known, known_bits_de(vec, dve, q, depth + 1));
        case .EXTRACTELEMENT;
            vec := op(i, 0); idx := op(i, 1);
            if type_kind(vtype(vec)) == .SVECTOR { kb_reset_all(*known); return known; }
            n := cast(u32) type_count(vtype(vec));
            dve := ap_all_ones(n);
            if is_scalar_const_int(idx) && ap_ult_u64(const_ap(idx), n) dve = ap_one_bit_set(n, cast(u32) ap_zext_value(const_ap(idx)));
            known = known_bits_de(vec, dve, q, depth + 1);
        case .EXTRACTVALUE;
            agg := op(i, 0);
            id := call_iid(agg);
            if id != NOT_INTRINSIC && inst(i).nidx == 1 && ir.u32_pool[inst(i).idx] == 0 {
                if id == IID_UADD_WITH_OVERFLOW || id == IID_SADD_WITH_OVERFLOW
                    known = known_bits_add_sub(true, op(agg, 0), op(agg, 1), false, false, de, q, depth);
                else if id == IID_USUB_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW
                    known = known_bits_add_sub(false, op(agg, 0), op(agg, 1), false, false, de, q, depth);
                else if id == IID_UMUL_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW
                    known = known_bits_mul(op(agg, 0), op(agg, 1), false, false, de, q, depth);
            }
        case .FREEZE;
            if is_guaranteed_not_to_be_poison(op(i, 0), q.ac, q.cxt, q.dt, depth + 1) known = known_bits(op(i, 0), q, depth + 1);
    }
    return known;
}

known_bits_shift_operands :: (i: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> (Known_Bits, Known_Bits, bool) {
    k2 := known_bits_de(op(i, 0), de, q, depth + 1);
    k := known_bits_de(op(i, 1), de, q, depth + 1);
    nz := kb_is_non_zero(k) || (ap_ult_u64(kb_max_value(k), kb_bits(k)) && is_known_non_zero_de(op(i, 1), de, q, depth + 1));
    return k2, k, nz;
}

// computeKnownBitsFromLerpPattern
known_bits_from_lerp_pattern :: (op0: Value_Id, op1: Value_Id, de: APInt, known_out: *Known_Bits, q: Simplify_Query, depth: u32) {
    ty := vtype(op0);
    bits := type_bits(scalar_type(ty));
    if is_vector_type(ty) return;
    Lerp :: struct { a: Value_Id = NONE; b: Value_Id = NONE; c: Value_Id = NONE; d: Value_Id = NONE; sub_bc: Value_Id = NONE; }
    match_sub_bc :: (v: Value_Id, m: *Lerp) -> bool {
        if !is_inst(v) return false;
        o := inst_op(v);
        if o == .SUB && (inst(v).flags & F_NUW) != 0 { m.b = op(v, 0); m.c = op(v, 1); m.sub_bc = v; return true; }
        if o == .XOR { m.c = op(v, 0); m.b = op(v, 1); m.sub_bc = v; return true; }
        return false;
    }
    match_a_sub_bc :: (v: Value_Id, m: *Lerp) -> bool {
        // m_CombineOr(m_c_Mul(m_Value(A), MatchSubBC()), MatchSubBC())
        if opr_code(v) == .MUL {
            x := op(v, 0); y := op(v, 1);
            save := m.*;
            if match_sub_bc(y, m) { m.a = x; return true; }
            m.* = save;
            if match_sub_bc(x, m) { m.a = y; return true; }
            m.* = save;
        }
        return match_sub_bc(v, m);
    }
    match_cd :: (v: Value_Id, m: *Lerp) -> bool {
        if opr_code(v) == .MUL {
            x := op(v, 0); y := op(v, 1);
            if y == m.c { m.d = x; return true; }
            if x == m.c { m.d = y; return true; }
        }
        return v == m.c;
    }
    m: Lerp;
    matched := false;
    if match_a_sub_bc(op0, *m) && match_cd(op1, *m) matched = true;
    else {
        m = .{};
        if match_a_sub_bc(op1, *m) && match_cd(op0, *m) matched = true;
    }
    if !matched return;
    kbo :: (v: Value_Id, bits: u32, de: APInt, q: Simplify_Query, depth: u32) -> Known_Bits {
        if v == NONE return kb_from_const(ap_one(bits));
        return known_bits_de(v, de, q, depth + 1);
    }
    ka := kbo(m.a, bits, de, q, depth);
    if !kb_is_non_negative(ka) return;
    kd := kbo(m.d, bits, de, q, depth);
    if !kb_is_non_negative(kd) return;
    kb := known_bits_de(m.b, de, q, depth + 1);
    if !kb_is_non_negative(kb) return;
    kc := known_bits_de(m.c, de, q, depth + 1);
    if !kb_is_non_negative(kc) return;
    if inst_op(m.sub_bc) == .XOR && !ap_is_subset_of(kb_max_value(kc), kb_min_value(kb)) return;
    max_ad := ap_umax(kb_max_value(ka), kb_max_value(kd));
    ub, ov := ap_umul_ov(max_ad, kb_max_value(kb));
    if ov return;
    ap_set_high_bits(*known_out.zero, ap_clz(ub));
}

// computeKnownBitsAddSub
known_bits_add_sub :: (add: bool, op0: Value_Id, op1: Value_Id, nsw: bool, nuw: bool, de: APInt, q: Simplify_Query, depth: u32) -> Known_Bits {
    known_out := known_bits_de(op1, de, q, depth + 1);
    if kb_is_unknown(known_out) && !nsw && !nuw return known_out;
    k2 := known_bits_de(op0, de, q, depth + 1);
    known_out = kb_compute_for_add_sub(add, nsw, nuw, k2, known_out);
    if !add && nsw && !kb_is_non_negative(known_out) {
        imp := is_implied_by_dom_condition_pred(ICMP_SLE, false, op1, op0, q.cxt);
        okm, _ := pm_c_min_max_with(op1, IID_SMIN, op0);
        if imp == 1 || okm kb_make_non_negative(*known_out);
    }
    if add known_bits_from_lerp_pattern(op0, op1, de, *known_out, q, depth);
    return known_out;
}

// computeKnownBitsMul
known_bits_mul :: (op0: Value_Id, op1: Value_Id, nsw: bool, nuw: bool, de: APInt, q: Simplify_Query, depth: u32) -> Known_Bits {
    known := known_bits_de(op1, de, q, depth + 1);
    known2 := known_bits_de(op0, de, q, depth + 1);
    is_neg := false; is_nneg := false;
    if nsw {
        if op0 == op1 is_nneg = true;
        else {
            nn1 := kb_is_non_negative(known); nn0 := kb_is_non_negative(known2);
            n1 := kb_is_negative(known); n0 := kb_is_negative(known2);
            is_nneg = (n1 && n0) || (nn1 && nn0);
            if !is_nneg && nuw {
                one := kb_from_const(ap_one(kb_bits(known)));
                is_nneg = kb_cmp_sgt(known, one) == 1 || kb_cmp_sgt(known2, one) == 1;
            }
            if !is_nneg is_neg = (n1 && nn0 && kb_is_non_zero(known2)) || (n0 && nn1 && kb_is_non_zero(known));
        }
    }
    self_mul := op0 == op1;
    if self_mul self_mul = is_guaranteed_not_to_be_undef(op0, q.ac, q.cxt, q.dt, depth + 1);
    known = kb_mul(known, known2, self_mul);
    if self_mul {
        sign_bits := num_sign_bits_de(op0, de, q, depth + 1);
        ty_bits := type_bits(scalar_type(vtype(op0)));
        out_valid := 2 * (ty_bits - sign_bits + 1);
        if out_valid < ty_bits known.zero = ap_or(known.zero, ap_high_bits_set(ty_bits, ty_bits - out_valid + 1));
    }
    if is_nneg && !kb_is_negative(known) kb_make_non_negative(*known);
    else if is_neg && !kb_is_non_negative(known) kb_make_negative(*known);
    return known;
}

// computeKnownBitsFromRangeMetadata
kb_from_range_metadata :: (m: Md_Id, bits: u32) -> Known_Bits {
    known := kb_new(bits);
    kb_set_all_conflict(*known);
    n := ir.mds[m].nops / 2;
    for p: 0..cast(s64) n - 1 {
        lo := const_ap(ir.mds[md_op(m, cast(u32)(2 * p))].value);
        hi := const_ap(ir.mds[md_op(m, cast(u32)(2 * p + 1))].value);
        r := cr_new(lo, hi);
        common := ap_clz(ap_xor(cr_umax(r), cr_umin(r)));
        mask := ap_high_bits_set(bits, common);
        umax := ap_zext_or_trunc(cr_umax(r), bits);
        known.one = ap_and(known.one, ap_and(umax, mask));
        known.zero = ap_and(known.zero, ap_and(ap_not(umax), mask));
    }
    return known;
}

// getKnownBitsFromAndXorOr
known_bits_and_xor_or :: (i: Value_Id, de: APInt, kl: Known_Bits, kr: Known_Bits, q: Simplify_Query, depth: u32) -> Known_Bits {
    bits := kb_bits(kl);
    out: Known_Bits;
    is_and := false;
    has_known_one := !ap_is_zero(kl.one) || !ap_is_zero(kr.one);
    o0 := op(i, 0); o1 := op(i, 1);
    opc := opr_code(i);
    if opc == .AND {
        out = kb_and(kl, kr);
        is_and = true;
        // m_c_And(m_Value(X), m_Neg(m_Deferred(X)))
        if has_known_one {
            okn1, x1 := pm_neg(o1);
            okn0, x0 := pm_neg(o0);
            if (okn1 && x1 == o0) || (okn0 && x0 == o1) {
                if kb_count_max_trailing_zeros(kl) <= kb_count_max_trailing_zeros(kr) out = kb_blsi(kl);
                else out = kb_blsi(kr);
            }
        }
    } else if opc == .OR {
        out = kb_or(kl, kr);
    } else {
        out = kb_xor(kl, kr);
        // m_c_Xor(m_Value(X), m_Add(m_Deferred(X), m_AllOnes()))
        if has_known_one {
            x: Value_Id = NONE;
            oka, a0, a1 := pm_binop(o1, .ADD);
            if oka && a0 == o0 && pm_all_ones(a1) x = o0;
            else {
                oka, a0, a1 = pm_binop(o0, .ADD);
                if oka && a0 == o1 && pm_all_ones(a1) x = o1;
            }
            if x != NONE out = kb_blsmsk(ifx o0 == x then kl else kr);
        }
    }
    if !ap_get_bit(out.zero, 0) && !ap_get_bit(out.one, 0) {
        // m_c_BinOp(m_Value(X), m_c_Add(m_Deferred(X), m_Value(Y))) / m_Sub(m_Deferred(X), m_Value(Y)) / m_Sub(m_Value(Y), m_Deferred(X))
        y: Value_Id = NONE;
        // the three alternatives are tried in order, each commuted over the outer binop
        try_add :: (x: Value_Id, other: Value_Id) -> Value_Id { ok, yy := pm_c_binop_with(other, .ADD, x); if ok return yy; return NONE; }
        try_sub_l :: (x: Value_Id, other: Value_Id) -> Value_Id { ok, s0, s1 := pm_binop(other, .SUB); if ok && s0 == x return s1; return NONE; }
        try_sub_r :: (x: Value_Id, other: Value_Id) -> Value_Id { ok, s0, s1 := pm_binop(other, .SUB); if ok && s1 == x return s0; return NONE; }
        y = try_add(o0, o1);
        if y == NONE y = try_add(o1, o0);
        if y == NONE y = try_sub_l(o0, o1);
        if y == NONE y = try_sub_l(o1, o0);
        if y == NONE y = try_sub_r(o0, o1);
        if y == NONE y = try_sub_r(o1, o0);
        if y != NONE {
            ky := known_bits_de(y, de, q, depth + 1);
            if kb_count_min_trailing_ones(ky) > 0 {
                out.zero = ap_copy(out.zero); out.one = ap_copy(out.one);
                if is_and ap_set_bit(*out.zero, 0); else ap_set_bit(*out.one, 0);
            }
        }
    }
    return out;
}

// getVScaleRange
get_vscale_range :: (f: Value_Id, bits: u32) -> Const_Range {
    a := fn_get_fn_attr(f, .VScaleRange);
    if !a return cr_new(ap_one(bits), ap_zero(bits));
    mn := a.ival >> 32;
    mx := a.ival & 0xFFFF_FFFF;
    if 64 - clz64(mn) > bits return cr_empty(bits);
    lo := ap_from_u64(bits, mn);
    if mx == 0 || 64 - clz64(mx) > bits return cr_new(lo, ap_zero(bits));
    return cr_new(lo, ap_add_u64(ap_from_u64(bits, mx), 1));
}

// adjustKnownBitsForSelectArm
adjust_known_bits_for_select_arm :: (known: *Known_Bits, cond: Value_Id, arm: Value_Id, invert: bool, q: Simplify_Query, depth: u32) {
    if kb_is_constant(known.*) return;
    cond_res := kb_new(kb_bits(known.*));
    known_bits_from_cond(arm, cond, *cond_res, q, invert, depth + 1);
    if kb_is_unknown(cond_res) return;
    cond_res = kb_union(cond_res, known.*);
    if kb_has_conflict(cond_res) return;
    if !is_guaranteed_not_to_be_undef(arm, q.ac, q.cxt, q.dt, depth + 1) return;
    known.* = cond_res;
}

// isSignedMinMaxIntrinsicClamp / unionWithMinMaxIntrinsicClamp
union_with_min_max_intrinsic_clamp :: (ii: Value_Id, known: *Known_Bits) {
    id := call_iid(ii);
    inverse := ifx id == IID_SMIN then IID_SMAX else IID_SMIN;
    inner := op(ii, 0);
    if call_iid(inner) != inverse return;
    ok1, clow := pm_apint(op(ii, 1));
    ok2, chigh := pm_apint(op(inner, 1));
    if !ok1 || !ok2 return;
    if id == IID_SMIN { t := clow; clow = chigh; chigh = t; }
    if !ap_sle(clow, chigh) return;
    known.* = kb_union(known.*, cr_to_known_bits(cr_non_empty(clow, ap_add_u64(chigh, 1))));
}

// computeKnownBitsFromOperator, case BitCast
known_bits_bitcast :: (i: Value_Id, de: APInt, known_in: Known_Bits, q: Simplify_Query, depth: u32) -> Known_Bits {
    known := known_in;
    bits := kb_bits(known);
    src := op(i, 0);
    st := vtype(src);
    if (type_kind(st) == .INT || type_kind(st) == .PTR) && !is_vector_type(vtype(i)) return known_bits(src, q, depth + 1);
    okb, v := pm_elementwise_bitcast(i);
    if okb && is_fp_type(scalar_type(vtype(v))) {
        fpt := scalar_type(vtype(v));
        res := compute_known_fp_class_de(v, de, FC_ALL_FLAGS, q, depth + 1);
        classes := res.known_fp_classes;
        if classes == FC_NONE return known;
        if kfpc_is_known_never(res, FC_NORMAL | FC_SUBNORMAL | FC_NAN) {
            kb_set_all_conflict(*known);
            if classes & FC_INF {
                inf := fp_inf(type_kind(fpt), false);
                known = kb_intersect(known, kb_from_const(ap_from_words(bits, inf)));
            }
            if classes & FC_ZERO known = kb_intersect(known, kb_from_const(ap_zero(type_bits(fpt))));
            ap_clear_sign_bit(*known.zero);
            ap_clear_sign_bit(*known.one);
        }
        if res.sign_bit >= 0 {
            if res.sign_bit == 1 kb_make_negative(*known); else kb_make_non_negative(*known);
        }
        return known;
    }
    dt := vtype(i);
    if type_kind(st) != .VECTOR || !is_int_type(type_elem(st)) || !is_int_type(scalar_type(dt)) || type_kind(dt) == .SVECTOR return known;
    n := de.bits;
    is_le := !dl.big_endian;
    sub_bits := type_int_width(type_elem(st));
    if bits % sub_bits == 0 {
        scale := bits / sub_bits;
        sub_de := ap_zero(n * scale);
        for e: 0..cast(s64) n - 1 if ap_get_bit(de, cast(u32) e) ap_set_bit(*sub_de, cast(u32) e * scale);
        for s: 0..cast(s64) scale - 1 {
            ks := known_bits_de(src, ap_shl(sub_de, cast(u32) s), q, depth + 1);
            shift_elt := ifx is_le then cast(u32) s else scale - 1 - cast(u32) s;
            known.zero = ap_copy(known.zero); known.one = ap_copy(known.one);
            kb_insert_bits(*known, ks, shift_elt * sub_bits);
        }
    }
    if sub_bits % bits == 0 {
        scale := sub_bits / bits;
        sub_de := ap_scale_bit_mask(de, n / scale);
        ks := known_bits_de(src, sub_de, q, depth + 1);
        kb_set_all_conflict(*known);
        for e: 0..cast(s64) n - 1 {
            if !ap_get_bit(de, cast(u32) e) continue;
            shifts := ifx is_le then cast(u32) e else n - 1 - cast(u32) e;
            offset := (shifts % scale) * bits;
            known = kb_intersect(known, kb_extract_bits(ks, bits, offset));
            if kb_is_unknown(known) break;
        }
    }
    return known;
}
// APIntOps::ScaleBitMask(A, NewBitWidth, MatchAllBits = false)
ap_scale_bit_mask :: (a: APInt, nbits: u32) -> APInt {
    old := a.bits;
    if old == nbits return a;
    r := ap_zero(nbits);
    if nbits > old {
        scale := nbits / old;
        for i: 0..cast(s64) old - 1 if ap_get_bit(a, cast(u32) i) ap_set_bits(*r, cast(u32) i * scale, (cast(u32) i + 1) * scale);
    } else {
        scale := old / nbits;
        for i: 0..cast(s64) nbits - 1 {
            sub := ap_extract_bits(a, scale, cast(u32) i * scale);
            if !ap_is_zero(sub) ap_set_bit(*r, cast(u32) i);
        }
    }
    return r;
}

// computeKnownBitsFromOperator, case GetElementPtr
known_bits_gep :: (i: Value_Id, bits: u32, q: Simplify_Query, depth: u32) -> Known_Bits {
    known := known_bits(op(i, 0), q, depth + 1);
    index_width := dl_index_bits(vtype(i));
    acc := ap_zero(index_width);
    add_index :: (known: *Known_Bits, ib: Known_Bits, index_width: u32, bits: u32) {
        if index_width == bits known.* = kb_add(known.*, ib);
        else {
            sum := kb_add(kb_trunc(known.*, index_width), ib);
            known.zero = ap_copy(known.zero); known.one = ap_copy(known.one);
            kb_insert_bits(known, sum, 0);
        }
    }
    cur := opr_gep_source_type(i);
    n := nops(i);
    for k: 1..cast(s64) n - 1 {
        if kb_is_unknown(known) break;
        index := op(i, cast(u32) k);
        // gep_type_iterator: operand k indexes `cur` (k == 1: the source element type as an array)
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, index);
        defer cur = indexed;
        if is_const(index) && is_null_value(index) continue;
        if is_struct {
            idx := index;
            if is_vector_type(vtype(idx)) idx = get_splat_value(idx);
            e := cast(u32) ap_zext_value(const_ap(idx));
            acc = ap_add_u64(acc, dl_struct_offset(cur, e));
            continue;
        }
        if !type_is_sized(indexed) { kb_reset_all(*known); break; }
        stride_scalable := type_kind(indexed) == .SVECTOR;
        stride := gep_seq_stride(cur, k, indexed);
        if !stride_scalable && is_scalar_const_int(index) {
            acc = ap_add(acc, ap_mul(ap_sext_or_trunc(const_ap(index), index_width), ap_from_u64(index_width, stride)));
            continue;
        }
        ib := kb_sext_or_trunc(known_bits(index, q, depth + 1), index_width);
        sf := kb_new(index_width);
        if stride_scalable ap_set_low_bits(*sf.zero, ctz64(stride));
        else sf = kb_from_const(ap_from_u64(index_width, stride));
        add_index(*known, kb_mul(ib, sf), index_width, bits);
    }
    if !kb_is_unknown(known) && !ap_is_zero(acc) add_index(*known, kb_from_const(acc), index_width, bits);
    return known;
}
// the GEP source element type of an instruction or constant expression
opr_gep_source_type :: (g: Value_Id) -> Type_Id {
    if vkind(g) == .INST return inst(g).ty2;
    return cexpr(g).ty2;
}
// gep_type_iterator::getIndexedType for operand k (k = 1 indexes the pointer, i.e. yields the source type)
gep_indexed_type :: (cur: Type_Id, k: s64, index: Value_Id) -> Type_Id {
    if k == 1 return cur;
    tk := type_kind(cur);
    if tk == .STRUCT {
        idx := index;
        if is_vector_type(vtype(idx)) idx = get_splat_value(idx);
        return type_sub(cur, cast(u32) ap_zext_value(const_ap(idx)));
    }
    if tk == .ARRAY || tk == .VECTOR || tk == .SVECTOR return type_elem(cur);
    fatal("internal: bad GEP index type");
    return cur;
}

// computeKnownBitsFromOperator, case PHI
known_bits_phi :: (p: Value_Id, de: APInt, bits: u32, q: Simplify_Query, depth: u32) -> Known_Bits {
    known := kb_new(bits);
    ok, bo, r, l := match_simple_recurrence(p);
    if ok {
        opc := inst_op(bo);
        if opc == .LSHR || opc == .ASHR || opc == .SHL || opc == .UDIV || opc == .UREM {
            if opc == .UREM || op(bo, 0) == p {
                rq := q; rq.cc = null; rq.cxt = p;
                k2 := known_bits_de(r, de, rq, depth + 1);
                if opc == .SHL ap_set_low_bits(*known.zero, kb_count_min_trailing_zeros(k2));
                else if opc == .ASHR {
                    ap_set_high_bits(*known.zero, kb_count_min_leading_zeros(k2));
                    ap_set_high_bits(*known.one, kb_count_min_leading_ones(k2));
                } else ap_set_high_bits(*known.zero, kb_count_min_leading_zeros(k2));
            }
        } else if opc == .ADD || opc == .SUB || opc == .AND || opc == .OR || opc == .MUL {
            rq := q; rq.cc = null;
            opnum: u32 = ifx op(p, 0) == r then cast(u32) 0 else 1;
            rinst := block_terminator(phi_block(p, opnum));
            linst := block_terminator(phi_block(p, 1 - opnum));
            rq.cxt = rinst;
            k2 := known_bits_de(r, de, rq, depth + 1);
            rq.cxt = linst;
            k3 := known_bits_de(l, de, rq, depth + 1);
            ap_set_low_bits(*known.zero, min(kb_count_min_trailing_zeros(k2), kb_count_min_trailing_zeros(k3)));
            if is_overflowing_binop(bo) && iiq_nsw(q, bo) {
                if opc == .ADD {
                    if kb_is_non_negative(k2) && kb_is_non_negative(k3) kb_make_non_negative(*known);
                    else if kb_is_negative(k2) && kb_is_negative(k3) kb_make_negative(*known);
                } else if opc == .SUB {
                    if op(bo, 0) == p {
                        if kb_is_non_negative(k2) && kb_is_negative(k3) kb_make_non_negative(*known);
                        else if kb_is_negative(k2) && kb_is_non_negative(k3) kb_make_negative(*known);
                    }
                } else if opc == .MUL {
                    if kb_is_non_negative(k2) && kb_is_non_negative(k3) kb_make_non_negative(*known);
                }
            }
        }
    }
    n := nops(p);
    if n == 0 return known;
    if depth < MAX_ANALYSIS_RECURSION_DEPTH - 1 && kb_is_unknown(known) {
        cv := phi_has_constant_value(p);
        if cv != NONE && pm_undef_value(cv) return known;
        kb_set_all_conflict(*known);
        for k: 0..n-1 {
            inc, cxt, cxt_phi := break_self_recursive_phi(p, k);
            if inc == p continue;
            rq := sq_with_instruction(q, cxt); rq.cc = null;
            k2 := known_bits_de(inc, de, rq, MAX_ANALYSIS_RECURSION_DEPTH - 1);
            if !kb_is_constant(k2) && cxt != NONE && inst_op(cxt) == .CONDBR {
                c := op(cxt, 0);
                okc, pred, ss, ca, cb := pm_icmp(c);
                if okc {
                    rhs: Value_Id = NONE;
                    if ca == inc rhs = cb;
                    else if cb == inc { rhs = ca; pred = cmp_swapped(pred); }
                    if rhs != NONE {
                        oka, rc := pm_apint(rhs);
                        if oka {
                            tsucc := op(cxt, 1); fsucc := op(cxt, 2);
                            pb := inst_block(cxt_phi);
                            if (tsucc == pb) != (fsucc == pb) {
                                if fsucc == pb pred = cmp_inverse(pred);
                                u := kb_union(k2, cr_to_known_bits(cr_exact_icmp_region(pred, rc)));
                                if kb_has_conflict(u) { kb_reset_all(*known); break; }
                                k2 = u;
                            }
                        }
                    }
                }
            }
            known = kb_intersect(known, k2);
            if kb_is_unknown(known) break;
        }
    }
    return known;
}

// breakSelfRecursivePHI: (value, context instruction, phi whose block the context branches to)
break_self_recursive_phi :: (p: Value_Id, k: u32) -> (Value_Id, Value_Id, Value_Id) {
    val := phi_value(p, k);
    if val == p return val, NONE, p;
    cxt := block_terminator(phi_block(p, k));
    phi_out := p;
    oks, c, t, f := pm_select(val);
    if oks {
        if t == p val = f;
        else if f == p val = t;
    }
    if is_phi(val) && nops(val) == 2 {
        for idx: 0..1 {
            if phi_value(val, cast(u32) idx) == p {
                nv := phi_value(val, cast(u32)(1 - idx));
                phi_out = val;
                cxt = block_terminator(phi_block(val, cast(u32)(1 - idx)));
                val = nv;
                break;
            }
        }
    }
    return val, cxt, phi_out;
}

// matchSimpleRecurrence(const PHINode *P, BinaryOperator *&BO, Value *&Start, Value *&Step) (matchTwoInputRecurrence)
match_simple_recurrence :: (p: Value_Id) -> (ok: bool, bo: Value_Id, start: Value_Id, step: Value_Id) {
    if nops(p) != 2 return false, NONE, NONE, NONE;
    for k: 0..1 {
        o := phi_value(p, cast(u32) k);
        if !is_binary_operator(o) continue;
        lhs := op(o, 0); rhs := op(o, 1);
        if lhs != p && rhs != p continue;
        return true, o, phi_value(p, cast(u32)(1 - k)), ifx lhs == p then rhs else lhs;
    }
    return false, NONE, NONE, NONE;
}

// computeKnownBitsFromOperator, case Call / Invoke
known_bits_call :: (i: Value_Id, de: APInt, known_in: Known_Bits, q: Simplify_Query, depth: u32) -> Known_Bits {
    known := known_in;
    bits := kb_bits(known);
    md := iiq_metadata(q, i, "range");
    if md != NONE known = kb_from_range_metadata(md, bits);
    okr, r := call_range(i);
    if okr known = kb_union(known, cr_to_known_bits(r));
    rv := call_returned_arg(i);
    if rv != NONE && vtype(rv) == vtype(i) {
        k2 := known_bits(rv, q, depth + 1);
        known = kb_union(known, k2);
        if kb_has_conflict(known) kb_reset_all(*known);
    }
    id := call_iid(i);
    if id == NOT_INTRINSIC return known;
    if id == {
        case IID_ABS;
            k2 := known_bits_de(op(i, 0), de, q, depth + 1);
            known = kb_union(known, kb_abs(k2, pm_one(op(i, 1))));
        case IID_BITREVERSE; known = kb_union(known, kb_reverse_bits(known_bits_de(op(i, 0), de, q, depth + 1)));
        case IID_BSWAP; known = kb_union(known, kb_byte_swap(known_bits_de(op(i, 0), de, q, depth + 1)));
        case IID_CTLZ;
            k2 := known_bits_de(op(i, 0), de, q, depth + 1);
            possible := kb_count_max_leading_zeros(k2);
            if op(i, 1) == const_int(ir.t_i1, 1) possible = min(possible, bits - 1);
            known.zero = ap_copy(known.zero);
            ap_set_bits_from(*known.zero, bit_width_u32(possible));
        case IID_CTTZ;
            k2 := known_bits_de(op(i, 0), de, q, depth + 1);
            possible := kb_count_max_trailing_zeros(k2);
            if op(i, 1) == const_int(ir.t_i1, 1) possible = min(possible, bits - 1);
            known.zero = ap_copy(known.zero);
            ap_set_bits_from(*known.zero, bit_width_u32(possible));
        case IID_CTPOP;
            k2 := known_bits_de(op(i, 0), de, q, depth + 1);
            known.zero = ap_copy(known.zero);
            ap_set_bits_from(*known.zero, bit_width_u32(kb_count_max_population(k2)));
        case IID_FSHR; #through;
        case IID_FSHL;
            oksa, sa := pm_apint(op(i, 2));
            if !oksa return known;
            k2 := known_bits_de(op(i, 0), de, q, depth + 1); k3 := known_bits_de(op(i, 1), de, q, depth + 1);
            known = ifx id == IID_FSHL then kb_fshl(k2, k3, sa) else kb_fshr(k2, k3, sa);
        case IID_CLMUL; known = kb_clmul(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_PEXT; known = kb_pext(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_PDEP; known = kb_pdep(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_UADD_SAT; known = kb_uadd_sat(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_USUB_SAT; known = kb_usub_sat(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_SADD_SAT; known = kb_sadd_sat(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_SSUB_SAT; known = kb_ssub_sat(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_VECTOR_REVERSE; known = known_bits_de(op(i, 0), ap_reverse_bits(de), q, depth + 1);
        case IID_VECTOR_REDUCE_AND; #through; case IID_VECTOR_REDUCE_OR; #through;
        case IID_VECTOR_REDUCE_UMAX; #through; case IID_VECTOR_REDUCE_UMIN; #through;
        case IID_VECTOR_REDUCE_SMAX; #through; case IID_VECTOR_REDUCE_SMIN;
            known = known_bits(op(i, 0), q, depth + 1);
        case IID_VECTOR_REDUCE_XOR;
            known = known_bits(op(i, 0), q, depth + 1);
            vt := vtype(op(i, 0));
            even := (type_count(vt) % 2) == 0;
            if even known.zero = ap_or(known.zero, known.one);
            if type_kind(vt) == .SVECTOR || even known.one = ap_zero(bits);
        case IID_VECTOR_REDUCE_ADD;
            vt := vtype(op(i, 0));
            if type_kind(vt) != .VECTOR return known;
            known = kb_reduce_add(known_bits(op(i, 0), q, depth + 1), cast(u32) type_count(vt));
        case IID_UMIN; known = kb_umin(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_UMAX; known = kb_umax(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_SMIN; known = kb_smin(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1)); union_with_min_max_intrinsic_clamp(i, *known);
        case IID_SMAX; known = kb_smax(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1)); union_with_min_max_intrinsic_clamp(i, *known);
        case IID_PTRMASK;
            known = known_bits_de(op(i, 0), de, q, depth + 1);
            k2 := known_bits_de(op(i, 1), de, q, depth + 1);
            known = kb_and(known, kb_anyext_or_trunc(k2, bits));
        case IID_X86_SSE2_PMULH_W; #through; case IID_X86_AVX2_PMULH_W; #through; case IID_X86_AVX512_PMULH_W_512;
            known = kb_mulhs(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_X86_SSE2_PMULHU_W; #through; case IID_X86_AVX2_PMULHU_W; #through; case IID_X86_AVX512_PMULHU_W_512;
            known = kb_mulhu(known_bits_de(op(i, 0), de, q, depth + 1), known_bits_de(op(i, 1), de, q, depth + 1));
        case IID_X86_SSE42_CRC32_64_64;
            known.zero = ap_copy(known.zero);
            ap_set_bits_from(*known.zero, 32);
        case IID_X86_SSSE3_PHADD_D_128; #through; case IID_X86_SSSE3_PHADD_W_128; #through;
        case IID_X86_AVX2_PHADD_D; #through; case IID_X86_AVX2_PHADD_W; #through;
        case IID_X86_SSSE3_PHADD_SW_128; #through; case IID_X86_AVX2_PHADD_SW; #through;
        case IID_X86_SSSE3_PHSUB_D_128; #through; case IID_X86_SSSE3_PHSUB_W_128; #through;
        case IID_X86_AVX2_PHSUB_D; #through; case IID_X86_AVX2_PHSUB_W; #through;
        case IID_X86_SSSE3_PHSUB_SW_128; #through; case IID_X86_AVX2_PHSUB_SW;
            fatal("known bits of x86 horizontal add/sub intrinsics are not supported yet");
        case IID_VSCALE;
            if inst(i).parent == NONE return known;
            known = cr_to_known_bits(get_vscale_range(inst_fn(i), bits));
    }
    return known;
}
bit_width_u32 :: (x: u32) -> u32 { if x == 0 return 0; return 64 - clz64(cast(u64) x); }

// computeKnownBitsFromOperator, case ShuffleVector
known_bits_shuffle :: (i: Value_Id, de: APInt, known_in: Known_Bits, q: Simplify_Query, depth: u32) -> Known_Bits {
    known := known_in;
    splat := vt_get_splat_value(i);
    if splat != NONE return known_bits(splat, q, depth + 1);
    if !is_inst(i) { kb_reset_all(*known); return known; }
    ok, dl_, dr := shuffle_demanded_elts(i, de);
    if !ok { kb_reset_all(*known); return known; }
    kb_set_all_conflict(*known);
    if !ap_is_zero(dl_) {
        known = known_bits_de(op(i, 0), dl_, q, depth + 1);
        if kb_is_unknown(known) return known;
    }
    if !ap_is_zero(dr) known = kb_intersect(known, known_bits_de(op(i, 1), dr, q, depth + 1));
    return known;
}
shuffle_mask :: (i: Value_Id) -> [] u32 {
    s: [] u32;
    if vkind(i) == .INST { r := inst(i); s.data = ir.u32_pool.data + r.idx; s.count = r.nidx; }
    else { e := cexpr(i); s.data = ir.u32_pool.data + e.idx; s.count = e.nidx; }
    return s;
}
// getShuffleDemandedElts (static wrapper + llvm::getShuffleDemandedElts with AllowUndefElts = false)
shuffle_demanded_elts :: (shuf: Value_Id, de: APInt) -> (bool, APInt, APInt) {
    if type_kind(vtype(shuf)) == .SVECTOR return true, de, de;
    src_width := cast(u32) type_count(vtype(op(shuf, 0)));
    dlhs := ap_zero(src_width); drhs := ap_zero(src_width);
    if ap_is_zero(de) return true, dlhs, drhs;
    mask := shuffle_mask(shuf);
    all0 := true;
    for mask if it != 0 { all0 = false; break; }
    if all0 { ap_set_bit(*dlhs, 0); return true, dlhs, drhs; }
    for m, idx: mask {
        if !ap_get_bit(de, cast(u32) idx) continue;
        if m == POISON_MASK_ELEM return false, dlhs, drhs;
        if m < src_width ap_set_bit(*dlhs, m); else ap_set_bit(*drhs, m - src_width);
    }
    return true, dlhs, drhs;
}
// llvm::getSplatValue (VectorUtils.cpp)
vt_get_splat_value :: (v: Value_Id) -> Value_Id {
    if is_vector_type(vtype(v)) && is_const(v) return get_splat_value(v);
    // m_Shuffle(m_InsertElt(m_Value(), m_Value(Splat), m_ZeroInt()), m_Value(), m_ZeroMask())
    if is_inst(v) && inst_op(v) == .SHUFFLEVECTOR {
        ie := op(v, 0);
        if is_inst(ie) && inst_op(ie) == .INSERTELEMENT && pm_zero_int(op(ie, 2)) {
            for shuffle_mask(v) if it != 0 && it != POISON_MASK_ELEM return NONE;   // m_ZeroMask: all 0 or undef
            return op(ie, 1);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- conditions and assumptions

// cmpExcludesZero
cmp_excludes_zero :: (pred: u8, rhs: Value_Id) -> bool {
    if pred == ICMP_UGT return true;
    if pred == ICMP_NE return pm_zero(rhs);
    zero := ap_zero(type_bits(scalar_type(vtype(rhs))));
    ok, c := pm_apint(rhs);
    if ok return !cr_contains(cr_exact_icmp_region(pred, c), zero);
    if vkind(rhs) != .C_DATA || !is_int_type(scalar_type(vtype(rhs))) || type_kind(vtype(rhs)) != .VECTOR return false;
    n := const_data_count(rhs);
    bits := zero.bits;
    for e: 0..cast(s64) n - 1 {
        if cr_contains(cr_exact_icmp_region(pred, ap_from_u64(bits, const_data_elt(rhs, cast(u64) e))), zero) return false;
    }
    return true;
}

// isEphemeralValueOf
is_ephemeral_value_of :: (i: Value_Id, e: Value_Id) -> bool {
    n := nops(i);
    for k: 0..cast(s64) n - 1 if op(i, cast(u32) k) == e return true;
    if !is_inst(e) return false;
    if e == i return true;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    table_set(*visited, e, true);
    array_add(*work, e);
    reaches := false;
    while work.count {
        v := pop(*work);
        u := ir.v_first_use[v];
        while u != NONE {
            ui := ir.u_user[u];
            u = ir.u_next[u];
            if ui == i { reaches = true; continue; }
            if may_have_side_effects(ui) || is_terminator(inst_op(ui)) return false;
            if !table_contains(*visited, ui) { table_set(*visited, ui, true); array_add(*work, ui); }
        }
    }
    return reaches;
}

// isValidAssumeForContext
is_valid_assume_for_context :: (inv: Value_Id, cxt: Value_Id, dt: *Dom_Tree, allow_ephemerals := false) -> bool {
    if inst_block(inv) == inst_block(cxt) {
        if comes_before(inv, cxt) return true;
        if !allow_ephemerals && inv == cxt return false;
        if !is_guaranteed_to_transfer_execution_range(cxt, inv, 15) return false;
        return allow_ephemerals || !is_ephemeral_value_of(inv, cxt);
    }
    if dt {
        if dt_dominates_inst(dt, inv, cxt) return true;
    } else {
        ib := inst_block(inv);
        if ib == block_single_predecessor(inst_block(cxt)) || ib == fn_entry(block_fn(ib)) return true;
    }
    return false;
}
is_valid_assume_q :: (inv: Value_Id, q: Simplify_Query) -> bool { return is_valid_assume_for_context(inv, q.cxt, q.dt, q.allow_ephemerals); }

// isKnownNonZeroFromAssume
is_known_non_zero_from_assume :: (v: Value_Id, q: Simplify_Query) -> bool {
    if !q.ac || q.cxt == NONE return false;
    for e: ac_assumptions_for(q.ac, v) {
        if vkind(e.assume) == .DEAD continue;
        i := e.assume;
        if e.index != AC_EXPR_RESULT_IDX {
            if assume_bundle_implies_non_null(v, inst_fn(q.cxt), i, e.index) && is_valid_assume_q(i, q) return true;
            continue;
        }
        okc, pred, ss, a, b := pm_icmp(op(i, 0));
        if !okc continue;
        is_v :: (x: Value_Id, v: Value_Id) -> bool { if x == v return true; okp, y := pm_cast(x, .PTRTOINT); return okp && y == v; }
        rhs: Value_Id = NONE;
        if is_v(a, v) rhs = b;
        else if is_v(b, v) { rhs = a; pred = cmp_swapped(pred); }
        if rhs == NONE continue;
        if cmp_excludes_zero(pred, rhs) && is_valid_assume_q(i, q) return true;
    }
    return false;
}
// assumeBundleImpliesNonNull-style query (llvm/lib/Analysis/AssumeBundleQueries.cpp): "nonnull"(V), or
// "dereferenceable"(V, N > 0) when null isn't defined
assume_bundle_implies_non_null :: (v: Value_Id, f: Value_Id, assume: Value_Id, k: u32) -> bool {
    tag := call_bundle_tag(assume, k);
    begin := ir.u32_pool[inst(assume).idx + 3 * k + 1];
    end := ir.u32_pool[inst(assume).idx + 3 * k + 2];
    if end == begin || op(assume, begin) != v return false;
    if tag == "nonnull" return true;
    if tag == "align" {
        // Ptr == Val && Alignment && Offset && isPowerOf2(Alignment) && Offset % Alignment != 0
        ok, p, al, off := assume_align_info(assume, k);
        if !ok return false;
        return al != 0 && (al & (al - 1)) == 0 && off % al != 0;
    }
    if tag == "dereferenceable" {
        if end - begin < 2 return false;
        okn, n := pm_apint(op(assume, begin + 1));
        if !okn return false;
        return !ap_is_zero(n) && !null_pointer_is_defined(f, ir.types[vtype(v)].a);
    }
    return false;
}

// computeKnownBitsFromCmp
known_bits_from_cmp :: (v: Value_Id, pred: u8, lhs: Value_Id, rhs: Value_Id, known: *Known_Bits, q: Simplify_Query) {
    if is_ptr_type(vtype(rhs)) {
        if lhs == v && pm_zero(rhs) {
            if pred == ICMP_EQ kb_set_all_zero(known);
            else if pred == ICMP_SGE || pred == ICMP_SGT kb_make_non_negative(known);
            else if pred == ICMP_SLT kb_make_negative(known);
        }
        return;
    }
    bits := kb_bits(known.*);
    // m_V = m_CombineOr(m_Specific(V), m_PtrToIntSameSize(DL, m_Specific(V)))
    is_v :: (x: Value_Id, v: Value_Id) -> bool {
        if x == v return true;
        if opr_code(x) == .PTRTOINT && op(x, 0) == v && type_bits(scalar_type(vtype(x))) == vt_bit_width(vtype(v)) return true;
        return false;
    }
    okc, c := pm_apint(rhs);
    if !okc return;
    if pred == ICMP_EQ {
        if is_v(lhs, v) {
            known.* = kb_union(known.*, kb_from_const(c));
            return;
        }
        lo := opr_code(lhs);
        if lo == .AND && (is_v(op(lhs, 0), v) || is_v(op(lhs, 1), v)) {
            y := ifx is_v(op(lhs, 0), v) then op(lhs, 1) else op(lhs, 0);
            known.one = ap_or(known.one, c);
            okm, mask := pm_apint(y);
            if okm known.zero = ap_or(known.zero, ap_and(ap_not(c), mask));
        } else if lo == .OR && (is_v(op(lhs, 0), v) || is_v(op(lhs, 1), v)) {
            y := ifx is_v(op(lhs, 0), v) then op(lhs, 1) else op(lhs, 0);
            known.zero = ap_or(known.zero, ap_not(c));
            okm, mask := pm_apint(y);
            if okm known.one = ap_or(known.one, ap_and(c, ap_not(mask)));
        } else if lo == .SHL && is_v(op(lhs, 0), v) {
            oks, sh := pm_constant_int_u64(op(lhs, 1));
            if oks && sh < bits {
                rk := kb_lshr_const(kb_from_const(c), cast(u32) sh);
                known.* = kb_union(known.*, rk);
            }
        } else if (lo == .LSHR || lo == .ASHR) && is_v(op(lhs, 0), v) {
            oks, sh := pm_constant_int_u64(op(lhs, 1));
            if oks && sh < bits {
                rk := kb_shl_const(kb_from_const(c), cast(u32) sh);
                known.* = kb_union(known.*, rk);
            }
        }
        return;
    }
    if pred == ICMP_NE {
        if ap_is_zero(c) && opr_code(lhs) == .AND && is_v(op(lhs, 0), v) {
            okp, p2 := pm_power2_ap(op(lhs, 1));
            if okp known.one = ap_or(known.one, p2);
        }
        return;
    }
    // default
    {
        has_offset := false; offset: APInt;
        matched := is_v(lhs, v);
        if !matched {
            oka, x, y := pm_add_like(lhs);
            if oka && is_v(x, v) {
                okf, off := pm_apint(y);
                if okf { matched = true; has_offset = true; offset = off; }
            }
        }
        if matched {
            r := cr_allowed_icmp_region(pred, cr_single(c));
            if has_offset r = cr_sub(r, cr_single(offset));
            known.* = kb_union(known.*, cr_to_known_bits(r));
        }
    }
    if pred == ICMP_UGT || pred == ICMP_UGE {
        lo := opr_code(lhs);
        if (lo == .AND && (is_v(op(lhs, 0), v) || is_v(op(lhs, 1), v))) || (lo == .SUB && (opr_flags(lhs) & F_NUW) != 0 && is_v(op(lhs, 0), v)) {
            cc := ifx pred == ICMP_UGT then ap_add_u64(c, 1) else c;
            known.one = ap_copy(known.one);
            ap_set_high_bits(*known.one, ap_clo(cc));
        }
    }
    if pred == ICMP_ULT || pred == ICMP_ULE {
        lo := opr_code(lhs);
        if (lo == .OR && (is_v(op(lhs, 0), v) || is_v(op(lhs, 1), v))) || (lo == .ADD && (opr_flags(lhs) & F_NUW) != 0 && (is_v(op(lhs, 0), v) || is_v(op(lhs, 1), v))) {
            cc := ifx pred == ICMP_ULT then ap_sub_u64(c, 1) else c;
            known.zero = ap_copy(known.zero);
            ap_set_high_bits(*known.zero, ap_clz(cc));
        }
    }
}

// computeKnownBitsFromICmpCond
known_bits_from_icmp_cond :: (v: Value_Id, cmp: Value_Id, known: *Known_Bits, q: Simplify_Query, invert: bool) {
    pred := inst_pred(cmp);
    if invert pred = cmp_inverse(pred);
    lhs := op(cmp, 0); rhs := op(cmp, 1);
    okt, tv := pm_cast(lhs, .TRUNC);
    if okt && tv == v {
        dst := kb_new(type_bits(scalar_type(vtype(lhs))));
        known_bits_from_cmp(lhs, pred, lhs, rhs, *dst, q);
        if (opr_flags(lhs) & F_NUW) != 0 known.* = kb_union(known.*, kb_zext(dst, kb_bits(known.*)));
        else known.* = kb_union(known.*, kb_anyext(dst, kb_bits(known.*)));
        return;
    }
    known_bits_from_cmp(v, pred, lhs, rhs, known, q);
}

// computeKnownBitsFromCond
known_bits_from_cond :: (v: Value_Id, cond: Value_Id, known: *Known_Bits, q: Simplify_Query, invert: bool, depth: u32) {
    if depth < MAX_ANALYSIS_RECURSION_DEPTH {
        okl, a, b := pm_logical_op(cond);
        if okl {
            k2 := kb_new(kb_bits(known.*)); k3 := kb_new(kb_bits(known.*));
            known_bits_from_cond(v, a, *k2, q, invert, depth + 1);
            known_bits_from_cond(v, b, *k3, q, invert, depth + 1);
            is_or, _, _ := pm_logical_or(cond);
            is_and, _, _ := pm_logical_and(cond);
            if (ifx invert then is_or else is_and) k2 = kb_union(k2, k3);
            else k2 = kb_intersect(k2, k3);
            known.* = kb_union(known.*, k2);
            return;
        }
    }
    if is_inst(cond) && inst_op(cond) == .ICMP {
        known_bits_from_icmp_cond(v, cond, known, q, invert);
        return;
    }
    okt, tv := pm_cast(cond, .TRUNC);
    if okt && tv == v {
        dst := kb_new(1);
        if invert kb_set_all_zero(*dst); else kb_set_all_ones(*dst);
        if (opr_flags(cond) & F_NUW) != 0 { known.* = kb_union(known.*, kb_zext(dst, kb_bits(known.*))); return; }
        known.* = kb_union(known.*, kb_anyext(dst, kb_bits(known.*)));
        return;
    }
    if depth < MAX_ANALYSIS_RECURSION_DEPTH {
        okn, x := pm_not(cond);
        if okn known_bits_from_cond(v, x, known, q, !invert, depth + 1);
    }
}

// computeKnownBitsFromContext
known_bits_from_context :: (v: Value_Id, known: *Known_Bits, q: Simplify_Query, depth: u32) {
    if q.cc && cc_affects(q.cc, v) known_bits_from_cond(v, q.cc.cond, known, q, q.cc.invert, depth);
    if q.cxt == NONE return;
    if q.dc && q.dt {
        cb := inst_block(q.cxt);
        for br: dc_conditions_for(q.dc, v) {
            if vkind(br) == .DEAD continue;
            bb := inst_block(br);
            if dt_dominates_edge_block(q.dt, bb, get_successor(br, 0), cb) known_bits_from_cond(v, op(br, 0), known, q, false, depth);
            if dt_dominates_edge_block(q.dt, bb, get_successor(br, 1), cb) known_bits_from_cond(v, op(br, 0), known, q, true, depth);
        }
        if kb_has_conflict(known.*) kb_reset_all(known);
    }
    if !q.ac return;
    bits := kb_bits(known.*);
    for e: ac_assumptions_for(q.ac, v) {
        if vkind(e.assume) == .DEAD continue;
        i := e.assume;
        if e.index != AC_EXPR_RESULT_IDX {
            ok, ptr, alignment, offset := assume_align_info(i, e.index);
            if ok && ptr == v && alignment != 0 && (alignment & (alignment - 1)) == 0 && is_valid_assume_q(i, q) {
                m := ap_from_u64(bits, alignment - 1);
                o := ap_from_u64(bits, offset);
                known.zero = ap_or(known.zero, ap_and(m, ap_not(o)));
                known.one = ap_or(known.one, ap_and(m, o));
            }
            continue;
        }
        arg := op(i, 0);
        if arg == v && is_valid_assume_q(i, q) { kb_set_all_ones(known); return; }
        okn, nx := pm_not(arg);
        if okn && nx == v && is_valid_assume_q(i, q) { kb_set_all_zero(known); return; }
        if is_inst(arg) && inst_op(arg) == .TRUNC && op(arg, 0) == v && is_valid_assume_q(i, q) {
            if (inst(arg).flags & F_NUW) != 0 { known.* = kb_from_const(ap_one(bits)); return; }
            known.one = ap_copy(known.one);
            ap_set_bit(*known.one, 0);
            return;
        }
        if depth == MAX_ANALYSIS_RECURSION_DEPTH continue;
        if !is_inst(arg) || inst_op(arg) != .ICMP continue;
        if !is_valid_assume_q(i, q) continue;
        known_bits_from_icmp_cond(v, arg, known, q, false);
    }
    if kb_has_conflict(known.*) kb_reset_all(known);
}
// getBundleAttrFromOBU == Align + getAssumeAlignInfo: "align"(ptr, alignment[, offset])
assume_align_info :: (assume: Value_Id, k: u32) -> (bool, Value_Id, u64, u64) {
    if call_bundle_tag(assume, k) != "align" return false, NONE, 0, 0;
    begin := ir.u32_pool[inst(assume).idx + 3 * k + 1];
    end := ir.u32_pool[inst(assume).idx + 3 * k + 2];
    if end - begin < 2 return false, NONE, 0, 0;
    ptr := op(assume, begin);
    oka, a := pm_constant_int_u64(op(assume, begin + 1));
    if !oka return false, NONE, 0, 0;
    off: u64 = 0;
    if end - begin > 2 {
        oko, o := pm_constant_int_u64(op(assume, begin + 2));
        if !oko return false, NONE, 0, 0;
        off = o;
    }
    return true, ptr, a, off;
}

// ---------------------------------------------------------------- isKnownToBeAPowerOfTwo

// isPowerOfTwoRecurrence
is_power_of_two_recurrence :: (pn: Value_Id, or_zero: bool, q_in: Simplify_Query, depth: u32) -> bool {
    q := q_in;
    ok, bo, start, step := match_simple_recurrence(pn);
    if !ok return false;
    n := nops(pn);
    for k: 0..n-1 {
        if phi_value(pn, k) == start {
            q.cxt = block_terminator(phi_block(pn, k));
            if !is_known_to_be_a_power_of_two(start, or_zero, q, depth) return false;
        }
    }
    if inst_op(bo) != .MUL && op(bo, 1) != step return false;
    q.cxt = block_terminator(inst_block(bo));
    if inst_op(bo) == {
        case .MUL; return (or_zero || iiq_nuw(q, bo) || iiq_nsw(q, bo)) && is_known_to_be_a_power_of_two(step, or_zero, q, depth);
        case .SDIV;
            if !pm_power2(start) || pm_sign_mask(start) return false;
            return (or_zero || iiq_exact(q, bo)) && is_known_to_be_a_power_of_two(step, false, q, depth);
        case .UDIV; return (or_zero || iiq_exact(q, bo)) && is_known_to_be_a_power_of_two(step, false, q, depth);
        case .SHL; return or_zero || iiq_nuw(q, bo) || iiq_nsw(q, bo);
        case .ASHR;
            if !pm_power2(start) || pm_sign_mask(start) return false;
            return or_zero || iiq_exact(q, bo);
        case .LSHR; return or_zero || iiq_exact(q, bo);
    }
    return false;
}
// isImpliedToBeAPowerOfTwoFromCond
is_implied_to_be_a_power_of_two_from_cond :: (v: Value_Id, or_zero: bool, cond: Value_Id, cond_is_true: bool) -> bool {
    ok, pred, ss, a, b := pm_icmp(cond);
    if !ok || call_iid(a) != IID_CTPOP || op(a, 0) != v return false;
    okc, rhsc := pm_apint(b);
    if !okc return false;
    if !cond_is_true pred = cmp_inverse(pred);
    if or_zero && pred == ICMP_ULT && ap_eq_u64(rhsc, 2) return true;
    return pred == ICMP_EQ && ap_eq_u64(rhsc, 1);
}
is_known_to_be_a_power_of_two_ctx :: (v: Value_Id, or_zero: bool, cxt: Value_Id, dt: *Dom_Tree, ac: *Assumption_Cache, use_instr_info := true, depth: u32 = 0) -> bool {
    q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = safe_cxt(v, cxt); q.use_instr_info = use_instr_info;
    return is_known_to_be_a_power_of_two(v, or_zero, q, depth);
}
// isKnownToBeAPowerOfTwo(const Value *V, bool OrZero, const SimplifyQuery &Q, unsigned Depth)
is_known_to_be_a_power_of_two :: (v: Value_Id, or_zero: bool, q: Simplify_Query, depth_in: u32 = 0) -> bool {
    depth := depth_in;
    if is_const(v) return ifx or_zero then pm_power2_or_zero(v) else pm_power2(v);
    if or_zero && type_bits(scalar_type(vtype(v))) == 1 return true;
    if q.ac && q.cxt != NONE {
        for e: ac_assumptions_for(q.ac, v) {
            if vkind(e.assume) == .DEAD continue;
            i := e.assume;
            if is_implied_to_be_a_power_of_two_from_cond(v, or_zero, op(i, 0), true) && is_valid_assume_q(i, q) return true;
        }
    }
    if q.dc && q.cxt != NONE && q.dt {
        cb := inst_block(q.cxt);
        for br: dc_conditions_for(q.dc, v) {
            if vkind(br) == .DEAD continue;
            c := op(br, 0); bb := inst_block(br);
            if is_implied_to_be_a_power_of_two_from_cond(v, or_zero, c, true) && dt_dominates_edge_block(q.dt, bb, get_successor(br, 0), cb) return true;
            if is_implied_to_be_a_power_of_two_from_cond(v, or_zero, c, false) && dt_dominates_edge_block(q.dt, bb, get_successor(br, 1), cb) return true;
        }
    }
    if !is_inst(v) return false;
    i := v;
    if q.cxt != NONE && call_iid(v) == IID_VSCALE return fn_has_fn_attr(inst_fn(q.cxt), .VScaleRange);
    okb, b0, b1 := pm_binop(i, .SHL);
    if okb && pm_one(b0) return true;
    okb, b0, b1 = pm_binop(i, .LSHR);
    if okb && pm_sign_mask(b0) return true;
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return false;
    depth += 1;
    o0 := op(i, 0);
    if inst_op(i) == {
        case .ZEXT; return is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
        case .TRUNC; return or_zero && is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
        case .SHL;
            if or_zero || iiq_nuw(q, i) || iiq_nsw(q, i) return is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
            return false;
        case .LSHR;
            if or_zero || iiq_exact(q, i) return is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
            return false;
        case .UDIV;
            if iiq_exact(q, i) return is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
            return false;
        case .MUL;
            return is_known_to_be_a_power_of_two(op(i, 1), or_zero, q, depth) && is_known_to_be_a_power_of_two(o0, or_zero, q, depth) &&
                   (or_zero || is_known_non_zero(i, q, depth));
        case .AND;
            o1 := op(i, 1);
            if or_zero && (is_known_to_be_a_power_of_two(o1, true, q, depth) || is_known_to_be_a_power_of_two(o0, true, q, depth)) return true;
            okn0, x0 := pm_neg(o0); okn1, x1 := pm_neg(o1);
            if (okn0 && x0 == o1) || (okn1 && x1 == o0) return or_zero || is_known_non_zero(o0, q, depth);
            return false;
        case .ADD;
            o1 := op(i, 1);
            if or_zero || iiq_nuw(q, i) || iiq_nsw(q, i) {
                okc, _ := pm_c_binop_with(o0, .AND, o1);
                if okc && is_known_to_be_a_power_of_two(o1, or_zero, q, depth) return true;
                okc2, _ := pm_c_binop_with(o1, .AND, o0);
                if okc2 && is_known_to_be_a_power_of_two(o0, or_zero, q, depth) return true;
                lb := known_bits(o0, q, depth);
                rb := known_bits(o1, q, depth);
                if ap_is_power_of_2(ap_not(ap_and(lb.zero, rb.zero)))
                    if or_zero || !ap_is_zero(rb.one) || !ap_is_zero(lb.one) return true;
            }
            if or_zero || iiq_nuw(q, i) {
                // m_Add(m_LShr(m_AllOnes(), m_Value()), m_One())
                okl, l0, _ := pm_binop(o0, .LSHR);
                if okl && pm_all_ones(l0) && pm_one(o1) return true;
            }
            return false;
        case .SELECT;
            return is_known_to_be_a_power_of_two(op(i, 1), or_zero, q, depth) && is_known_to_be_a_power_of_two(op(i, 2), or_zero, q, depth);
        case .PHI;
            rq := q; rq.cc = null;
            if is_power_of_two_recurrence(i, or_zero, rq, depth) return true;
            nd := max(depth, MAX_ANALYSIS_RECURSION_DEPTH - 1);
            n := nops(i);
            for k: 0..n-1 {
                u := phi_value(i, k);
                if u == i continue;
                rq.cxt = block_terminator(phi_block(i, k));
                if !is_known_to_be_a_power_of_two(u, or_zero, rq, nd) return false;
            }
            return true;
        case .INVOKE; #through;
        case .CALL;
            id := call_iid(i);
            if id == {
                case IID_UMAX; #through; case IID_SMAX; #through; case IID_UMIN; #through; case IID_SMIN;
                    return is_known_to_be_a_power_of_two(op(i, 1), or_zero, q, depth) && is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
                case IID_BITREVERSE; #through; case IID_BSWAP;
                    return is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
                case IID_FSHR; #through; case IID_FSHL;
                    if o0 == op(i, 1) return is_known_to_be_a_power_of_two(o0, or_zero, q, depth);
            }
            return false;
    }
    return false;
}

// ---------------------------------------------------------------- isKnownNonZero

// isGEPKnownNonNull
is_gep_known_non_null :: (gep: Value_Id, q: Simplify_Query, depth_in: u32) -> bool {
    depth := depth_in;
    f: Value_Id = NONE;
    if is_inst(gep) f = inst_fn(gep);
    fl := opr_flags(gep);
    if (fl & F_GEP_NUW) == 0 && !((fl & F_INBOUNDS) != 0 && !null_pointer_is_defined(f, ir.types[vtype(gep)].a)) return false;
    if is_known_non_zero(op(gep, 0), q, depth) return true;
    cur := opr_gep_source_type(gep);
    n := nops(gep);
    for k: 1..cast(s64) n - 1 {
        index := op(gep, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, index);
        defer cur = indexed;
        if is_struct {
            e := cast(u32) ap_zext_value(const_ap(index));
            if dl_struct_offset(cur, e) > 0 return true;
            continue;
        }
        if gep_seq_stride(cur, k, indexed) == 0 continue;
        if is_scalar_const_int(index) {
            if !ap_is_zero(const_ap(index)) return true;
            continue;
        }
        if depth >= MAX_ANALYSIS_RECURSION_DEPTH { depth += 1; continue; }
        depth += 1;
        if is_known_non_zero(index, q, depth) return true;
    }
    return false;
}

// getLoadStorePointerOperand
load_store_pointer_operand :: (i: Value_Id) -> Value_Id {
    if !is_inst(i) return NONE;
    if inst_op(i) == .LOAD return op(i, 0);
    if inst_op(i) == .STORE return op(i, 1);
    return NONE;
}
// isGuard
is_guard :: (v: Value_Id) -> bool { return call_iid(v) == IID_EXPERIMENTAL_GUARD; }

// isKnownNonNullFromDominatingCondition
is_known_non_null_from_dominating_condition :: (v: Value_Id, cxt: Value_Id, dt: *Dom_Tree) -> bool {
    if cxt == NONE || !dt return false;
    explored := 0;
    u := ir.v_first_use[v];
    while u != NONE {
        defer u = ir.u_next[u];
        if explored >= DOM_CONDITIONS_MAX_USES break;
        explored += 1;
        ui := ir.u_user[u];
        if !is_inst(ui) continue;
        if is_ptr_type(vtype(v)) && is_call_base(ui) {
            argno := u - ir.v_ops[ui];
            if argno < call_num_args(ui) && call_param_has_nonnull_attr(ui, argno, false) && dt_dominates_inst(dt, ui, cxt) return true;
        }
        if v == load_store_pointer_operand(ui) {
            if !null_pointer_is_defined(inst_fn(ui), ir.types[vtype(v)].a) && dt_dominates_inst(dt, ui, cxt) return true;
        }
        uo := inst_op(ui);
        if (uo == .UDIV || uo == .SDIV || uo == .UREM || uo == .SREM) && op(ui, 1) == v && is_valid_assume_for_context(ui, cxt, dt) return true;
        okc, pred, ss, a, b := pm_icmp(ui);
        if !okc continue;
        rhs: Value_Id = NONE;
        if a == v rhs = b; else if b == v { rhs = a; pred = cmp_swapped(pred); } else continue;
        non_null_if_true: bool;
        if cmp_excludes_zero(pred, rhs) non_null_if_true = true;
        else if cmp_excludes_zero(cmp_inverse(pred), rhs) non_null_if_true = false;
        else continue;
        work: [..] Value_Id; work.allocator = temp;
        visited: [..] Value_Id; visited.allocator = temp;
        visit :: (visited: *[..] Value_Id, x: Value_Id) -> bool { for visited.* if it == x return false; array_add(visited, x); return true; }
        cu := ir.v_first_use[ui];
        while cu != NONE {
            cmp_user := ir.u_user[cu];
            cu = ir.u_next[cu];
            if visit(*visited, cmp_user) array_add(*work, cmp_user);
            while work.count {
                curr := pop(*work);
                if non_null_if_true {
                    okl, _, _ := pm_logical_and(curr);
                    if okl {
                        uu := ir.v_first_use[curr];
                        while uu != NONE { cc := ir.u_user[uu]; uu = ir.u_next[uu]; if visit(*visited, cc) array_add(*work, cc); }
                        continue;
                    }
                }
                if is_inst(curr) && inst_op(curr) == .CONDBR {
                    succ := op(curr, ifx non_null_if_true then cast(u32) 1 else 2);
                    if dt_dominates_edge_block(dt, inst_block(curr), succ, inst_block(cxt)) return true;
                } else if non_null_if_true && is_guard(curr) && dt_dominates_inst(dt, curr, cxt) return true;
            }
        }
    }
    return false;
}
// CallBase::paramHasNonNullAttr(ArgNo, AllowUndefOrPoison)
call_param_has_nonnull_attr :: (c: Value_Id, argno: u32, allow_undef_or_poison: bool) -> bool {
    if call_param_has_attr(c, argno, .NonNull) && (allow_undef_or_poison || call_param_has_attr(c, argno, .NoUndef)) return true;
    d := call_param_attr(c, argno, .Dereferenceable);
    if d && d.ival > 0 && !null_pointer_is_defined(inst_fn(c), ir.types[vtype(op(c, argno))].a) return true;
    return false;
}

// rangeMetadataExcludesValue
range_metadata_excludes_value :: (m: Md_Id, v: APInt) -> bool {
    n := ir.mds[m].nops / 2;
    for p: 0..cast(s64) n - 1 {
        lo := const_ap(ir.mds[md_op(m, cast(u32)(2 * p))].value);
        hi := const_ap(ir.mds[md_op(m, cast(u32)(2 * p + 1))].value);
        if cr_contains(cr_new(lo, hi), v) return false;
    }
    return true;
}
// isNonZeroRecurrence
is_non_zero_recurrence :: (pn: Value_Id) -> bool {
    ok, bo, start, step := match_simple_recurrence(pn);
    if !ok return false;
    oks, sc := pm_apint(start);
    if !oks || ap_is_zero(sc) return false;
    fl := inst(bo).flags;
    if inst_op(bo) == {
        case .ADD;
            if fl & F_NUW return true;
            okt, stc := pm_apint(step);
            return (fl & F_NSW) != 0 && okt && ap_is_negative(sc) == ap_is_negative(stc);
        case .MUL;
            okt, stc := pm_apint(step);
            return (fl & (F_NUW | F_NSW)) != 0 && okt && !ap_is_zero(stc);
        case .SHL; return (fl & (F_NUW | F_NSW)) != 0;
        case .ASHR; #through;
        case .LSHR; return (fl & F_EXACT) != 0;
    }
    return false;
}
// matchOpWithOpEqZero
match_op_with_op_eq_zero :: (op0: Value_Id, op1: Value_Id) -> bool {
    test :: (a: Value_Id, b: Value_Id) -> bool {
        ok, x := pm_zext_or_sext(a);
        if !ok return false;
        okc, pred, ss, l, r := pm_icmp(x);
        return okc && pred == ICMP_EQ && l == b && pm_zero(r);
    }
    return test(op0, op1) || test(op1, op0);
}
is_non_zero_add :: (de: APInt, q: Simplify_Query, bits: u32, x: Value_Id, y: Value_Id, nsw: bool, nuw: bool, depth: u32) -> bool {
    if match_op_with_op_eq_zero(x, y) return true;
    if nuw return is_known_non_zero_de(y, de, q, depth) || is_known_non_zero_de(x, de, q, depth);
    xk := known_bits_de(x, de, q, depth);
    yk := known_bits_de(y, de, q, depth);
    if kb_is_non_negative(xk) && kb_is_non_negative(yk)
        if is_known_non_zero_de(y, de, q, depth) || is_known_non_zero_de(x, de, q, depth) return true;
    if kb_is_negative(xk) && kb_is_negative(yk) {
        mask := ap_signed_max(bits);
        if ap_intersects(xk.one, mask) return true;
        if ap_intersects(yk.one, mask) return true;
    }
    if kb_is_non_negative(xk) && is_known_to_be_a_power_of_two(y, false, q, depth) return true;
    if kb_is_non_negative(yk) && is_known_to_be_a_power_of_two(x, false, q, depth) return true;
    return kb_is_non_zero(kb_add(xk, yk, nsw, nuw));
}
is_non_zero_sub :: (de: APInt, q: Simplify_Query, bits: u32, x: Value_Id, y: Value_Id, depth: u32) -> bool {
    if match_op_with_op_eq_zero(x, y) return true;
    if is_const(x) && is_null_value(x) && is_known_non_zero_de(y, de, q, depth) return true;
    return is_known_non_equal_de(x, y, de, q, depth);
}
is_non_zero_mul :: (de: APInt, q: Simplify_Query, bits: u32, x: Value_Id, y: Value_Id, nsw: bool, nuw: bool, depth: u32) -> bool {
    if nsw || nuw return is_known_non_zero_de(x, de, q, depth) && is_known_non_zero_de(y, de, q, depth);
    xk := known_bits_de(x, de, q, depth);
    if ap_get_bit(xk.one, 0) return is_known_non_zero_de(y, de, q, depth);
    yk := known_bits_de(y, de, q, depth);
    if ap_get_bit(yk.one, 0) return kb_is_non_zero(xk) || is_known_non_zero_de(x, de, q, depth);
    return kb_count_max_trailing_zeros(xk) + kb_count_max_trailing_zeros(yk) < bits;
}
is_non_zero_shift :: (i: Value_Id, de: APInt, q: Simplify_Query, kv: Known_Bits, depth: u32) -> bool {
    opc := opr_code(i);
    shift_op :: (opc: Opcode, l: APInt, r: APInt) -> APInt {
        if opc == .SHL return ap_shl_ap(l, r);
        if opc == .LSHR return ap_lshr_ap(l, r);
        return ap_ashr_ap(l, r);
    }
    inv_shift_op :: (opc: Opcode, l: APInt, r: APInt) -> APInt {
        if opc == .SHL return ap_lshr_ap(l, r);
        return ap_shl_ap(l, r);
    }
    if kb_is_unknown(kv) return false;
    kc := known_bits_de(op(i, 1), de, q, depth);
    max_shift := kb_max_value(kc);
    nb := kb_bits(kv);
    if ap_uge_u64(max_shift, nb) return false;
    if !ap_is_zero(shift_op(opc, kv.one, max_shift)) return true;
    amt := ap_sub(ap_from_u64(max_shift.bits, nb), max_shift);
    if ap_eq(inv_shift_op(opc, kv.zero, amt), inv_shift_op(opc, ap_all_ones(nb), amt)) && is_known_non_zero_de(op(i, 0), de, q, depth) return true;
    return false;
}

// isKnownNonZeroFromOperator
is_known_non_zero_from_operator :: (i: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    bits := vt_bit_width(scalar_type(vtype(i)));
    opc := opr_code(i);
    if opc == {
        case .ALLOCA; return ir.types[scalar_type(vtype(i))].a == 0;
        case .GEP;
            if is_ptr_type(vtype(i)) return is_gep_known_non_null(i, q, depth);
        case .BITCAST;
            from := vtype(op(i, 0));
            fs := scalar_type(from);
            if (is_int_type(fs) || is_ptr_type(fs)) && (bits % vt_bit_width(fs)) == 0 return is_known_non_zero(op(i, 0), q, depth);
        case .INTTOPTR;
            if type_kind(vtype(i)) != .SVECTOR && dl_type_size_bits(vtype(op(i, 0))) <= dl_type_size_bits(vtype(i)) return is_known_non_zero_de(op(i, 0), de, q, depth);
        case .PTRTOADDR; return is_known_non_zero_de(op(i, 0), de, q, depth);
        case .PTRTOINT;
            if dl_index_bits(vtype(op(i, 0))) <= type_bits(scalar_type(vtype(i))) return is_known_non_zero_de(op(i, 0), de, q, depth);
        case .TRUNC;
            if is_inst(i) && (inst(i).flags & (F_NUW | F_NSW)) != 0 return is_known_non_zero_de(op(i, 0), de, q, depth);
        case .XOR; #through;
        case .SUB; return is_non_zero_sub(de, q, bits, op(i, 0), op(i, 1), depth);
        case .OR;
            if match_op_with_op_eq_zero(op(i, 0), op(i, 1)) return true;
            if is_known_non_equal_de(op(i, 0), op(i, 1), de, q, depth) return true;
            return is_known_non_zero_de(op(i, 1), de, q, depth) || is_known_non_zero_de(op(i, 0), de, q, depth);
        case .SEXT; #through;
        case .ZEXT; return is_known_non_zero_de(op(i, 0), de, q, depth);
        case .SHL;
            if iiq_nuw(q, i) || iiq_nsw(q, i) return is_known_non_zero_de(op(i, 0), de, q, depth);
            k := known_bits_de(op(i, 0), de, q, depth);
            if ap_get_bit(k.one, 0) return true;
            return is_non_zero_shift(i, de, q, k, depth);
        case .LSHR; #through;
        case .ASHR;
            if (opr_flags(i) & F_EXACT) != 0 return is_known_non_zero_de(op(i, 0), de, q, depth);
            k := known_bits_de(op(i, 0), de, q, depth);
            if kb_is_negative(k) return true;
            if depth + 1 < MAX_ANALYSIS_RECURSION_DEPTH {
                o0 := op(i, 0);
                if opr_code(o0) == .ADD && (opr_flags(o0) & F_NUW) != 0 {
                    okc, c := pm_apint(op(i, 1));
                    if okc && ap_ult_u64(c, bits) {
                        ka := known_bits_de(op(o0, 0), de, q, depth + 1);
                        if !ap_is_zero(ap_lshr_ap(ka.one, c)) return true;
                        kb := known_bits_de(op(o0, 1), de, q, depth + 1);
                        if !ap_is_zero(ap_lshr_ap(kb.one, c)) return true;
                    }
                }
            }
            return is_non_zero_shift(i, de, q, k, depth);
        case .UDIV; #through;
        case .SDIV;
            if (opr_flags(i) & F_EXACT) != 0 return is_known_non_zero_de(op(i, 0), de, q, depth);
            xk := known_bits_de(op(i, 0), de, q, depth);
            if kb_is_unknown(xk) return false;
            yk := known_bits_de(op(i, 1), de, q, depth);
            if opc == .SDIV { xk = kb_abs(xk, false); yk = kb_abs(yk, false); }
            return kb_cmp_uge(xk, yk) == 1;
        case .ADD; return is_non_zero_add(de, q, bits, op(i, 0), op(i, 1), iiq_nsw(q, i), iiq_nuw(q, i), depth);
        case .MUL; return is_non_zero_mul(de, q, bits, op(i, 0), op(i, 1), iiq_nsw(q, i), iiq_nuw(q, i), depth);
        case .SELECT;
            arm_non_zero :: (i: Value_Id, true_arm: bool, de: APInt, q: Simplify_Query, depth: u32) -> bool {
                o := op(i, ifx true_arm then cast(u32) 1 else 2);
                if is_known_non_zero_de(o, de, q, depth) return true;
                okc, pred, ss, a, b := pm_icmp(op(i, 0));
                if !okc return false;
                x: Value_Id = NONE;
                if a == o x = b; else if b == o { x = a; pred = cmp_swapped(pred); } else return false;
                if !true_arm pred = cmp_inverse(pred);
                return cmp_excludes_zero(pred, x);
            }
            if arm_non_zero(i, true, de, q, depth) && arm_non_zero(i, false, de, q, depth) return true;
        case .PHI;
            if q.use_instr_info && is_non_zero_recurrence(i) return true;
            rq := q; rq.cc = null;
            nd := max(depth, MAX_ANALYSIS_RECURSION_DEPTH - 1);
            n := nops(i);
            for k: 0..n-1 {
                u := phi_value(i, k);
                if u == i continue;
                rq.cxt = block_terminator(phi_block(i, k));
                if rq.cxt != NONE && inst_op(rq.cxt) == .CONDBR {
                    okc, pred, ss, a, b := pm_icmp(op(rq.cxt, 0));
                    if okc {
                        x: Value_Id = NONE;
                        if a == u x = b; else if b == u { x = a; pred = cmp_swapped(pred); }
                        if x != NONE {
                            tsucc := op(rq.cxt, 1); fsucc := op(rq.cxt, 2);
                            pb := inst_block(i);
                            if (tsucc == pb) != (fsucc == pb) {
                                if fsucc == pb pred = cmp_inverse(pred);
                                if cmp_excludes_zero(pred, x) continue;
                            }
                        }
                    }
                }
                if !is_known_non_zero_de(u, de, rq, nd) return false;
            }
            return true;
        case .INSERTELEMENT;
            if type_kind(vtype(i)) == .SVECTOR return false;
            vec := op(i, 0); elt := op(i, 1); cidx := op(i, 2);
            n := de.bits;
            dve := ap_copy(de);
            skip := false;
            if is_scalar_const_int(cidx) && ap_ult_u64(const_ap(cidx), n) {
                ix := cast(u32) ap_zext_value(const_ap(cidx));
                ap_clear_bit(*dve, ix);
                skip = !ap_get_bit(de, ix);
            }
            return (skip || is_known_non_zero(elt, q, depth)) && (ap_is_zero(dve) || is_known_non_zero_de(vec, dve, q, depth));
        case .EXTRACTELEMENT;
            if is_inst(i) {
                vec := op(i, 0); idx := op(i, 1);
                if type_kind(vtype(vec)) == .VECTOR {
                    n := cast(u32) type_count(vtype(vec));
                    dve := ap_all_ones(n);
                    if is_scalar_const_int(idx) && ap_ult_u64(const_ap(idx), n) dve = ap_one_bit_set(n, cast(u32) ap_zext_value(const_ap(idx)));
                    return is_known_non_zero_de(vec, dve, q, depth);
                }
            }
        case .SHUFFLEVECTOR;
            if !is_inst(i) return is_known_non_zero_fallback(i, de, q, depth);
            ok, dlhs, drhs := shuffle_demanded_elts(i, de);
            if !ok return is_known_non_zero_fallback(i, de, q, depth);
            return (ap_is_zero(drhs) || is_known_non_zero_de(op(i, 1), drhs, q, depth)) && (ap_is_zero(dlhs) || is_known_non_zero_de(op(i, 0), dlhs, q, depth));
        case .FREEZE;
            return is_known_non_zero(op(i, 0), q, depth) && is_guaranteed_not_to_be_poison(op(i, 0), q.ac, q.cxt, q.dt, depth);
        case .LOAD;
            if is_ptr_type(vtype(i)) {
                if iiq_metadata(q, i, "nonnull") != NONE || (iiq_metadata(q, i, "dereferenceable") != NONE && !null_pointer_is_defined(inst_fn(i), ir.types[vtype(i)].a)) return true;
            } else {
                m := iiq_metadata(q, i, "range");
                if m != NONE return range_metadata_excludes_value(m, ap_zero(bits));
            }
            return false;
        case .EXTRACTVALUE;
            if is_inst(i) && inst(i).nidx == 1 && ir.u32_pool[inst(i).idx] == 0 {
                wo := op(i, 0);
                id := call_iid(wo);
                if id == IID_UADD_WITH_OVERFLOW || id == IID_SADD_WITH_OVERFLOW return is_non_zero_add(de, q, bits, op(wo, 0), op(wo, 1), false, false, depth);
                if id == IID_USUB_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW return is_non_zero_sub(de, q, bits, op(wo, 0), op(wo, 1), depth);
                if id == IID_UMUL_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW return is_non_zero_mul(de, q, bits, op(wo, 0), op(wo, 1), false, false, depth);
            }
        case .CALL; #through;
        case .INVOKE;
            if is_ptr_type(vtype(i)) {
                if call_is_return_non_null(i) return true;
                rp := argument_aliasing_to_returned_pointer(i, true);
                if rp != NONE return is_known_non_zero(rp, q, depth);
            } else {
                m := iiq_metadata(q, i, "range");
                if m != NONE return range_metadata_excludes_value(m, ap_zero(bits));
                okr, r := call_range(i);
                if okr && !cr_contains(r, ap_zero(cr_bits(r))) return true;
                rv := call_returned_arg(i);
                if rv != NONE && vtype(rv) == vtype(i) && is_known_non_zero(rv, q, depth) return true;
            }
            id := call_iid(i);
            if id != NOT_INTRINSIC {
                a0 := op(i, 0);
                if id == {
                    case IID_SSHL_SAT; #through; case IID_USHL_SAT; #through; case IID_ABS; #through;
                    case IID_BITREVERSE; #through; case IID_BSWAP; #through; case IID_CTPOP;
                        return is_known_non_zero_de(a0, de, q, depth);
                    case IID_SSUB_SAT;
                        if bits == 1 return false;
                        return is_non_zero_sub(de, q, bits, a0, op(i, 1), depth);
                    case IID_SADD_SAT; return is_non_zero_add(de, q, bits, a0, op(i, 1), true, false, depth);
                    case IID_VECTOR_REVERSE; return is_known_non_zero_de(a0, ap_reverse_bits(de), q, depth);
                    case IID_VECTOR_REDUCE_OR; #through; case IID_VECTOR_REDUCE_UMAX; #through; case IID_VECTOR_REDUCE_UMIN; #through;
                    case IID_VECTOR_REDUCE_SMAX; #through; case IID_VECTOR_REDUCE_SMIN;
                        return is_known_non_zero(a0, q, depth);
                    case IID_UMAX; #through; case IID_UADD_SAT;
                        if match_op_with_op_eq_zero(a0, op(i, 1)) return true;
                        return is_known_non_zero_de(op(i, 1), de, q, depth) || is_known_non_zero_de(a0, de, q, depth);
                    case IID_SMAX;
                        nz0: s8 = -1; nz1: s8 = -1;
                        is_nz :: (o: Value_Id, cache: *s8, k: Known_Bits, de: APInt, q: Simplify_Query, depth: u32) -> bool {
                            if cache.* < 0 cache.* = ifx kb_is_non_zero(k) || is_known_non_zero_de(o, de, q, depth) then cast(s8) 1 else 0;
                            return cache.* == 1;
                        }
                        k1 := known_bits_de(op(i, 1), de, q, depth);
                        if kb_is_non_negative(k1) && is_nz(op(i, 1), *nz1, k1, de, q, depth) return true;
                        k0 := known_bits_de(a0, de, q, depth);
                        if kb_is_non_negative(k0) && is_nz(a0, *nz0, k0, de, q, depth) return true;
                        return is_nz(op(i, 1), *nz1, k1, de, q, depth) && is_nz(a0, *nz0, k0, de, q, depth);
                    case IID_SMIN;
                        k1 := known_bits_de(op(i, 1), de, q, depth);
                        if kb_is_negative(k1) return true;
                        k0 := known_bits_de(a0, de, q, depth);
                        if kb_is_negative(k0) return true;
                        if kb_is_non_zero(k1) && kb_is_non_zero(k0) return true;
                        return is_known_non_zero_de(a0, de, q, depth) && is_known_non_zero_de(op(i, 1), de, q, depth);
                    case IID_UMIN;
                        return is_known_non_zero_de(a0, de, q, depth) && is_known_non_zero_de(op(i, 1), de, q, depth);
                    case IID_CTTZ; return ap_get_bit(known_bits_de(a0, de, q, depth).zero, 0);
                    case IID_CTLZ; return kb_is_non_negative(known_bits_de(a0, de, q, depth));
                    case IID_FSHR; #through; case IID_FSHL;
                        if a0 == op(i, 1) return is_known_non_zero_de(a0, de, q, depth);
                    case IID_VSCALE; return true;
                    case IID_EXPERIMENTAL_GET_VECTOR_LENGTH; return is_known_non_zero(a0, q, depth);
                }
                return is_known_non_zero_fallback(i, de, q, depth);
            }
            return false;
    }
    return is_known_non_zero_fallback(i, de, q, depth);
}
is_known_non_zero_fallback :: (i: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    k := known_bits_de(i, de, q, depth);
    return !ap_is_zero(k.one);
}

is_known_non_zero :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool {
    return is_known_non_zero_de(v, dem_all(vtype(v)), q, depth);
}
// isKnownNonZero(const Value *V, const APInt &DemandedElts, const SimplifyQuery &Q, unsigned Depth)
is_known_non_zero_de :: (v: Value_Id, de: APInt, q: Simplify_Query, depth_in: u32) -> bool {
    depth := depth_in;
    ty := vtype(v);
    k := vkind(v);
    if is_constant_kind(k) {
        if is_null_value(v) return false;
        if k == .C_INT return true;
        if type_kind(ty) == .VECTOR {
            n := type_count(ty);
            for e: 0..cast(s64) n - 1 {
                if !ap_get_bit(de, cast(u32) e) continue;
                elt := cf_elt(v, cast(u64) e);
                if elt == NONE || is_null_value(elt) return false;
                if vkind(elt) != .C_POISON && vkind(elt) != .C_INT return false;
            }
            return true;
        }
        if k == .C_PTRAUTH return is_known_non_zero_de(op(v, 0), de, q, depth);
        if is_global_value(k) {
            if get_metadata(v, md_kind_id("absolute_symbol")) == NONE && glob(v).linkage != .EXTERN_WEAK && ir.types[vtype(v)].a == 0 return true;
        }
        if k != .C_EXPR return false;
    }
    if k == .ARGUMENT {
        okr, r := arg_range(v);
        if okr && !cr_contains(r, ap_zero(cr_bits(r))) return true;
    }
    if !is_constant_kind(k) && is_known_non_zero_from_assume(v, q) return true;
    if depth >= MAX_ANALYSIS_RECURSION_DEPTH return false;
    depth += 1;
    if is_ptr_type(ty) && k == .ARGUMENT {
        if (arg_has_pass_pointee_by_value_copy(v) && !null_pointer_is_defined(arg_parent(v), ir.types[ty].a)) || arg_has_nonnull_attr(v) return true;
    }
    if k == .INST || k == .C_EXPR {
        if is_known_non_zero_from_operator(v, de, q, depth) return true;
    }
    if !is_constant_kind(k) && is_known_non_null_from_dominating_condition(v, q.cxt, q.dt) return true;
    stripped := strip_null_test(v);
    if stripped != NONE return is_known_non_zero_de(stripped, de, q, depth);
    return false;
}

// stripNullTest
strip_null_test :: (v: Value_Id) -> Value_Id {
    if !is_binary_operator(v) return NONE;
    o := inst_op(v);
    if o != .ADD && o != .OR return NONE;
    // m_c_BinOp(m_LShr(m_Value(X), m_APInt(C1)), m_ZExt(m_SpecificICmp(NE, m_And(m_Deferred(X), m_LowBitMask(C2)), m_Zero())))
    for k: 0..1 {
        a := op(v, cast(u32) k); b := op(v, cast(u32)(1 - k));
        okl, x, c1v := pm_binop(a, .LSHR);
        if !okl continue;
        ok1, c1 := pm_apint(c1v);
        if !ok1 continue;
        okz, z := pm_cast(b, .ZEXT);
        if !okz continue;
        okc, pred, ss, cl, cr := pm_icmp(z);
        if !okc || pred != ICMP_NE || !pm_zero(cr) continue;
        oka, a0, a1 := pm_binop(cl, .AND);
        if !oka || a0 != x continue;
        okm, c2 := pm_low_bit_mask_ap(a1);
        if !okm continue;
        if ap_popcount(c2) == ap_zext_value(c1) return x;
    }
    return NONE;
}
