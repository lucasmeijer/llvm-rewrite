// SLPVectorizer: options and the static helpers in front of BoUpSLP.
// Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (the cl::opts, isValidElementType ... getNumberOfParts,
// BinOpSameOpcodeHelper, InstructionsState, getSameOpcode, the small mask/order helpers) and
// llvm/lib/Transforms/Vectorize/SLPVectorizer/SLPUtils.cpp (complete), plus getIntrinsicForCallSite
// (llvm/lib/Analysis/ValueTracking.cpp) and getVectorIntrinsicIDForCall (llvm/lib/Analysis/VectorUtils.cpp).
// Not ported (fail loudly when reached): REVEC (-slp-revec), struct-typed scalars, VFDatabase vector variants.

slp_cl: struct {
    run := true;                          // -vectorize-slp
    revec := false;                       // -slp-revec
    threshold: s64 = 0;                   // -slp-threshold
    vectorize_hor := true;                // -slp-vectorize-hor
    vectorize_hor_store := false;         // -slp-vectorize-hor-store
    split_alternate := true;              // -slp-split-alternate-instructions
    inst_count_check := true;             // -slp-inst-count-check
    max_reg_size: s64 = 128;              // -slp-max-reg-size
    max_vf: s64 = 0;                      // -slp-max-vf
    schedule_budget: s64 = 100000;        // -slp-schedule-budget
    min_reg_size: s64 = 128;              // -slp-min-reg-size
    recursion_max_depth: s64 = 12;        // -slp-recursion-max-depth
    min_tree_size: s64 = 3;               // -slp-min-tree-size
    phi_budget: s64 = 1024;               // -slp-phi-vectorization-budget
    look_ahead_max_depth: s64 = 2;        // -slp-max-look-ahead-depth
    root_look_ahead_max_depth: s64 = 2;   // -slp-max-root-look-ahead-depth
    min_strided_loads: s64 = 2;           // -slp-min-strided-loads
    min_strided_stores: s64 = 2;          // -slp-min-strided-stores
    max_stride: s64 = 8;                  // -slp-max-stride
    strided_stores := false;              // -slp-enable-strided-stores
    masked_stores := true;                // -slp-enable-masked-stores
    disable_tree_reorder := false;        // -slp-disable-tree-reorder
    force_strided_loads := false;         // -slp-force-strided-loads
    non_power_of_2 := false;              // -slp-vectorize-non-power-of-2
    postprocess_stores_operands := false; // -slp-postprocess-stores-operands
    non_vect_reductions := false;         // -slp-non-vectorizables-as-reductions
    poor_throughput := true;              // -slp-vectorize-poor-throughput
    copyable := true;                     // -slp-copyable-elements
    loop_trip_count: s64 = 2;             // -slp-cost-loop-trip-count
    per_lane_gather_scale := true;        // -slp-per-lane-gather-scale
    max_reg_size_given: bool;             // getNumOccurrences() of -slp-max-reg-size / -slp-min-reg-size / -slp-max-vf
    min_reg_size_given: bool;
    max_vf_given: bool;
    threshold_given: bool;              // SLPCostThreshold.getNumOccurrences() > 0
};

slp_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    b :: (p: *bool, name: string, value: string, has_value: bool) {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" p.* = true;
        else if value == "false" || value == "0" || value == "FALSE" || value == "False" p.* = false;
        else fatal("invalid boolean value '%' for option -%", value, name);
    }
    n :: (p: *s64, name: string, value: string, has_value: bool, unsigned := false) {
        if !has_value fatal("option -% requires a value", name);
        v, ok := string_to_int(value);
        if !ok || (unsigned && v < 0) fatal("invalid integer value '%' for option -%", value, name);
        p.* = v;
    }
    if name == {
        case "vectorize-slp"; b(*slp_cl.run, name, value, has_value);
        case "slp-revec"; b(*slp_cl.revec, name, value, has_value);
        case "slp-threshold"; n(*slp_cl.threshold, name, value, has_value); slp_cl.threshold_given = true;
        case "slp-vectorize-hor"; b(*slp_cl.vectorize_hor, name, value, has_value);
        case "slp-vectorize-hor-store"; b(*slp_cl.vectorize_hor_store, name, value, has_value);
        case "slp-split-alternate-instructions"; b(*slp_cl.split_alternate, name, value, has_value);
        case "slp-inst-count-check"; b(*slp_cl.inst_count_check, name, value, has_value);
        case "slp-max-reg-size"; n(*slp_cl.max_reg_size, name, value, has_value); slp_cl.max_reg_size_given = true;
        case "slp-max-vf"; n(*slp_cl.max_vf, name, value, has_value, true); slp_cl.max_vf_given = true;
        case "slp-schedule-budget"; n(*slp_cl.schedule_budget, name, value, has_value);
        case "slp-min-reg-size"; n(*slp_cl.min_reg_size, name, value, has_value); slp_cl.min_reg_size_given = true;
        case "slp-recursion-max-depth"; n(*slp_cl.recursion_max_depth, name, value, has_value, true);
        case "slp-min-tree-size"; n(*slp_cl.min_tree_size, name, value, has_value, true);
        case "slp-phi-vectorization-budget"; n(*slp_cl.phi_budget, name, value, has_value, true);
        case "slp-max-look-ahead-depth"; n(*slp_cl.look_ahead_max_depth, name, value, has_value);
        case "slp-max-root-look-ahead-depth"; n(*slp_cl.root_look_ahead_max_depth, name, value, has_value);
        case "slp-min-strided-loads"; n(*slp_cl.min_strided_loads, name, value, has_value, true);
        case "slp-min-strided-stores"; n(*slp_cl.min_strided_stores, name, value, has_value, true);
        case "slp-max-stride"; n(*slp_cl.max_stride, name, value, has_value, true);
        case "slp-enable-strided-stores"; b(*slp_cl.strided_stores, name, value, has_value);
        case "slp-enable-masked-stores"; b(*slp_cl.masked_stores, name, value, has_value);
        case "slp-disable-tree-reorder"; b(*slp_cl.disable_tree_reorder, name, value, has_value);
        case "slp-force-strided-loads"; b(*slp_cl.force_strided_loads, name, value, has_value);
        case "slp-vectorize-non-power-of-2"; b(*slp_cl.non_power_of_2, name, value, has_value);
        case "slp-postprocess-stores-operands"; b(*slp_cl.postprocess_stores_operands, name, value, has_value);
        case "slp-non-vectorizables-as-reductions"; b(*slp_cl.non_vect_reductions, name, value, has_value);
        case "slp-vectorize-poor-throughput"; b(*slp_cl.poor_throughput, name, value, has_value);
        case "slp-copyable-elements"; b(*slp_cl.copyable, name, value, has_value);
        case "slp-cost-loop-trip-count"; n(*slp_cl.loop_trip_count, name, value, has_value, true);
        case "slp-per-lane-gather-scale"; b(*slp_cl.per_lane_gather_scale, name, value, has_value);
        case "view-slp-tree"; fatal("-view-slp-tree is not supported");
        case; return false;
    }
    if slp_cl.revec fatal("slp-vectorizer: -slp-revec (REVEC) is not supported yet");
    return true;
}

SLP_ALIASED_CHECK_LIMIT :: 10;
SLP_USES_LIMIT :: 64;
SLP_MAX_MEM_DEP_DISTANCE :: 160;
SLP_MIN_SCHEDULE_REGION_SIZE :: 16;
SLP_MAX_PHI_NUM_OPERANDS :: 128;

slp_fail :: (what: string) { fatal("slp-vectorizer: % is not supported yet", what); }

// bit helpers (llvm/Support/MathExtras.h)
has_single_bit :: (x: u64) -> bool { return x != 0 && (x & (x - 1)) == 0; }
bit_floor :: (x: u64) -> u64 { if x == 0 return 0; r: u64 = 1; while r <= x / 2 r *= 2; return r; }
bit_ceil :: (x: u64) -> u64 { if x <= 1 return 1; r: u64 = 1; while r < x r *= 2; return r; }
divide_ceil :: (a: u64, b: u64) -> u64 { return (a + b - 1) / b; }
slp_power_of_2_ceil :: (x: u64) -> u64 { if x == 0 return 0; return bit_ceil(x); }   // PowerOf2Ceil

// isAllowedNonPowerOf2VF
slp_is_allowed_non_power_of_2_vf :: (n: u64) -> bool { return slp_cl.non_power_of_2 && has_single_bit(n + 1); }

// VectorType::isValidElementType
vector_type_is_valid_element_type :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .INT || is_fp_type(t) || k == .PTR || k == .BYTE return true;
    if k == .TARGET_EXT fatal("slp-vectorizer: target extension types as vector elements are not supported yet");
    return false;
}
// canVectorizeTy
can_vectorize_ty :: (t: Type_Id) -> bool {
    if type_kind(t) == .STRUCT {
        n := cast(s64) type_nsub(t);
        if n == 0 || ir.types[t].name.count != 0 || ir.types[t].a != 0 return false;
        for k: 0..n-1 if !vector_type_is_valid_element_type(type_sub(t, cast(u32) k)) return false;
        return true;
    }
    return type_kind(t) == .VOID || vector_type_is_valid_element_type(t);
}
// isValidElementType
slp_is_valid_element_type :: (t: Type_Id) -> bool {
    return can_vectorize_ty(t) && type_kind(t) != .X86_FP80 && type_kind(t) != .PPC_FP128 && type_kind(t) != .VOID;
}
// getValueType(V, LookThroughCmp)
slp_get_value_type :: (v: Value_Id, look_through_cmp := false) -> Type_Id {
    if is_inst(v) {
        o := inst_op(v);
        if o == .STORE return vtype(op(v, 0));
        if look_through_cmp && (o == .ICMP || o == .FCMP) return vtype(op(v, 0));
        if o == .INSERTELEMENT return vtype(op(v, 1));
        if o == .INSERTVALUE return vtype(op(v, 1));
    }
    return vtype(v);
}
// getNumElements(Ty) (SLPUtils.cpp)
slp_num_elements :: (t: Type_Id) -> u64 {
    if type_kind(t) == .SVECTOR fatal("internal: slp: scalable vector type");
    if is_vectorized_ty(t) {
        if type_kind(t) == .STRUCT return type_count(type_sub(t, 0));
        return type_count(t);
    }
    return 1;
}
// getWidenedType(ScalarTy, VF)
slp_widened_type :: (sty: Type_Id, vf: u64) -> Type_Id {
    if type_kind(sty) == .STRUCT slp_fail("struct-typed scalars");
    if is_vector_type(sty) slp_fail("vector-typed scalars (REVEC)");
    return type_vector(vf, sty, false);
}
// TTI::getNumberOfParts (BasicTTIImplBase: the legalization split count; 0 when invalid)
tti_number_of_parts :: (t: *Tti, ty: Type_Id) -> u64 {
    if t.kind != .X86 return 1;   // TargetTransformInfoImplBase::getNumberOfParts
    c, m := bt_type_legalization_cost(*t.xl, ty);
    if !cost_valid(c) return 0;
    // non-power-of-2 vectors: ceil(num-of-elements / num-of-subtype-elements) when the legal type has the same element
    if type_kind(ty) == .VECTOR && mvt_is_vec(m) && !mvt_is_scalable(m) && !has_single_bit(type_count(ty)) {
        elt := type_elem(ty);
        same := (is_int_type(elt) && mvt_is_int(m) && cast(u32) type_int_width(elt) == mvt_scalar_bits(m)) ||
                (is_fp_type(elt) && mvt_is_fp(m) && cast(u32) dl_type_size_bits(elt) == mvt_scalar_bits(m));
        if same return divide_ceil(type_count(ty), cast(u64) mvt_n(m));
    }
    return cast(u64) c;
}
// getFullVectorNumberOfElements
slp_full_vector_number_of_elements :: (t: *Tti, ty: Type_Id, sz: u64) -> u64 {
    if !slp_is_valid_element_type(ty) || type_kind(ty) == .STRUCT return bit_ceil(sz);
    parts := tti_number_of_parts(t, slp_widened_type(ty, sz));
    if parts == 0 || parts >= sz return bit_ceil(sz);
    return bit_ceil(divide_ceil(sz, parts)) * parts;
}
// getFloorFullVectorNumberOfElements
slp_floor_full_vector_number_of_elements :: (t: *Tti, ty: Type_Id, sz: u64) -> u64 {
    if !slp_is_valid_element_type(ty) || type_kind(ty) == .STRUCT return bit_floor(sz);
    parts := tti_number_of_parts(t, slp_widened_type(ty, sz));
    if parts == 0 || parts >= sz return bit_floor(sz);
    reg_vf := bit_ceil(divide_ceil(sz, parts));
    if reg_vf > sz return bit_floor(sz);
    return (sz / reg_vf) * reg_vf;
}
// hasFullVectorsOrPowerOf2
slp_has_full_vectors_or_power_of_2 :: (t: *Tti, ty: Type_Id, sz: u64) -> bool {
    if sz <= 1 return false;
    if !slp_is_valid_element_type(ty) && type_kind(ty) != .VECTOR return false;
    if has_single_bit(sz) return true;
    if type_kind(ty) == .STRUCT return false;
    parts := tti_number_of_parts(t, slp_widened_type(ty, sz));
    return parts > 0 && parts < sz && has_single_bit(sz / parts) && sz % parts == 0;
}
// getNumberOfParts(TTI, VecTy, ScalarTy, Limit)
slp_number_of_parts :: (t: *Tti, vec_ty: Type_Id, sty: Type_Id, limit: u64 = 0xFFFF_FFFF) -> u64 {
    if type_kind(vec_ty) == .STRUCT return 1;
    parts := tti_number_of_parts(t, vec_ty);
    if parts == 0 || parts >= limit return 1;
    sz := slp_num_elements(vec_ty);
    ssz := slp_num_elements(sty);
    elt := scalar_type(vec_ty);
    pw := slp_full_vector_number_of_elements(t, elt, sz);
    if parts >= sz || pw % parts != 0 || (pw / parts) % ssz != 0 || !slp_has_full_vectors_or_power_of_2(t, elt, pw / parts) return 1;
    n := pw / parts;
    if divide_ceil(sz, n) != parts return 1;
    return parts;
}

// ---------------------------------------------------------------- SLPUtils.cpp

// isConstant: a constant, but not a global or constant expression
slp_is_constant :: (v: Value_Id) -> bool {
    k := vkind(v);
    return is_constant_kind(k) && k != .C_EXPR && !(k >= .GLOBAL_VAR && k <= .IFUNC);
}
// isVectorLikeInstWithConstOps
slp_is_vector_like_inst_with_const_ops :: (v: Value_Id) -> bool {
    if pm_undef_value(v) return true;
    if !is_inst(v) return false;
    o := inst_op(v);
    if o == .EXTRACTVALUE return true;
    if o == .EXTRACTELEMENT return type_kind(vtype(op(v, 0))) == .VECTOR && slp_is_constant(op(v, 1));
    if o == .INSERTELEMENT return type_kind(vtype(op(v, 0))) == .VECTOR && slp_is_constant(op(v, 2));
    return o == .INSERTVALUE;
}
// getPartNumElems / getNumElems
slp_part_num_elems :: (size: u64, parts: u64) -> u64 { return min(size, bit_ceil(divide_ceil(size, parts))); }
slp_num_elems :: (size: u64, part_elems: u64, part: u64) -> u64 { return min(part_elems, size - part * part_elems); }
// allSameBlock
slp_all_same_block :: (vl: [] Value_Id) -> bool {
    first := -1;
    for vl if is_inst(it) { first = it_index; break; }
    if first < 0 return false;
    all_vec_like := true;
    for vl if !slp_is_vector_like_inst_with_const_ops(it) { all_vec_like = false; break; }
    if all_vec_like return true;
    bb := inst_block(vl[first]);
    for k: first..vl.count-1 {
        v := vl[k];
        if pm_poison(v) continue;
        if !is_inst(v) return false;
        if inst_block(v) != bb return false;
    }
    return true;
}
// allConstant
slp_all_constant :: (vl: [] Value_Id) -> bool { for vl if !slp_is_constant(it) return false; return true; }
// isSplat
slp_is_splat :: (vl: [] Value_Id) -> bool {
    first: Value_Id = NONE;
    for vl {
        if pm_undef_value(it) continue;
        if first == NONE { first = it; continue; }
        if it != first return false;
    }
    return first != NONE;
}
// allSameOpcode
slp_all_same_opcode :: (vl: [] Value_Id) -> bool {
    first := -1;
    for vl if is_inst(it) { first = it_index; break; }
    if first < 0 return true;
    main := vl[first];
    opc := inst_op(main);
    is_cmp := opc == .ICMP || opc == .FCMP;
    base_pred: u8 = ifx is_cmp then inst(main).pred else BAD_ICMP_PREDICATE;
    for k: first..vl.count-1 {
        v := vl[k];
        if is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP) { if base_pred != inst(v).pred return false; continue; }
        if is_inst(v) { if inst_op(v) != opc return false; continue; }
        if !pm_poison(v) return false;
    }
    return true;
}
// getExtractIndex: (ok, index)
slp_extract_index :: (e: Value_Id) -> (bool, u64) {
    if inst_op(e) == .EXTRACTELEMENT {
        c := op(e, 1);
        if vkind(c) != .C_INT return false, 0;
        ap := cf_ap(c);
        if !ap_fits_u64(ap) return false, 0;
        idx := ap_zext_value(ap);
        if (idx & 0xFFFF_FFFF) >= slp_num_elements(vtype(op(e, 0))) return false, 0;   // `unsigned Idx = CI->getZExtValue()`
        return true, idx & 0xFFFF_FFFF;
    }
    if inst(e).nidx != 1 return false, 0;
    return true, ir.u32_pool[inst(e).idx];
}
// allSameType
slp_all_same_type :: (vl: [] Value_Id) -> bool { for vl if vtype(it) != vtype(vl[0]) return false; return true; }
// getInsertExtractIndex<InsertElementInst / ExtractElementInst>(Inst, Offset)
slp_insert_extract_index :: (v: Value_Id, insert: bool, offset: u64) -> (bool, u64) {
    if !is_inst(v) || inst_op(v) != (ifx insert then Opcode.INSERTELEMENT else .EXTRACTELEMENT) return false, 0;
    vt := ifx insert then vtype(v) else vtype(op(v, 0));
    if type_kind(vt) != .VECTOR return false, 0;
    c := op(v, ifx insert then cast(u32) 2 else 1);
    if vkind(c) != .C_INT return false, 0;
    ap := cf_ap(c);
    if !ap_ult_u64(ap, type_count(vt)) return false, 0;
    return true, offset * type_count(vt) + ap_zext_value(ap);
}

// ---------------------------------------------------------------- commutativity, element indices

// isCommutative(I, ValWithUses, IsCopyable)
slp_is_commutative_with :: (i: Value_Id, with_uses: Value_Id, is_copyable := false) -> bool {
    o := inst_op(i);
    if o == .ICMP return icmp_is_equality(inst(i).pred);
    if o == .FCMP return fcmp_is_commutative(inst(i).pred);
    if is_binary_op(o) {
        if is_commutative_op(o) return true;
        has_use_list := !is_constant_data(with_uses);
        if o == .SUB && has_use_list && !has_n_uses_or_more(with_uses, SLP_USES_LIMIT) {
            ok := true;
            u := ir.v_first_use[with_uses];
            while u != NONE {
                usr := ir.u_user[u]; val := ir.u_val[u];
                u = ir.u_next[u];
                if is_inst(usr) && inst_op(usr) == .ICMP && op(usr, 0) == val && pm_zero(op(usr, 1)) &&
                   (inst(usr).pred == ICMP_EQ || inst(usr).pred == ICMP_NE) continue;
                // abs(sub nsw, true) or abs(sub, false)
                if call_iid(usr) == IID_ABS && op(usr, 0) == val && vkind(op(usr, 1)) == .C_INT {
                    flag_one := ap_is_one(cf_ap(op(usr, 1)));
                    vi := is_inst(val) && is_binary_op(inst_op(val));
                    if (!is_copyable && vi && (inst(val).flags & F_NSW) == 0) || flag_one continue;
                }
                ok = false; break;
            }
            if ok return true;
        }
        if o == .FSUB && has_use_list && !has_n_uses_or_more(with_uses, SLP_USES_LIMIT) {
            ok := true;
            u := ir.v_first_use[with_uses];
            while u != NONE {
                usr := ir.u_user[u]; val := ir.u_val[u];
                u = ir.u_next[u];
                if call_iid(usr) == IID_FABS && op(usr, 0) == val continue;
                ok = false; break;
            }
            if ok return true;
        }
        return false;
    }
    return inst_is_commutative(i);
}
slp_is_commutative :: (i: Value_Id) -> bool { return slp_is_commutative_with(i, i); }
// isCommutableOperand(I, ValWithUses, Op, IsCopyable)
slp_is_commutable_operand :: (i: Value_Id, op_idx: u32) -> bool {
    o := inst_op(i);
    if o == .ICMP || o == .FCMP return true;
    if o == .SUB || o == .FSUB return true;
    if is_binary_op(o) return op_idx < 2;
    // Instruction::isCommutableOperand: the first two operands of a commutative intrinsic
    return op_idx < 2;
}
// getNumberOfPotentiallyCommutativeOps
slp_num_potentially_commutative_ops :: (i: Value_Id) -> u32 {
    if call_iid(i) != NOT_INTRINSIC && slp_is_commutative(i) return 2;
    return nops(i);
}
// getElementIndex(Inst, Offset)
slp_element_index :: (v: Value_Id, offset: u64 = 0) -> (bool, u64) {
    ok, x := slp_insert_extract_index(v, true, offset);
    if ok return true, x;
    ok, x = slp_insert_extract_index(v, false, offset);
    if ok return true, x;
    if !is_inst(v) || inst_op(v) != .INSERTVALUE return false, 0;
    index := offset;
    cur := vtype(v);
    r := inst(v);
    for k: 0..cast(s64) r.nidx - 1 {
        idx := cast(u64) ir.u32_pool[r.idx + cast(u32) k];
        if type_kind(cur) == .STRUCT { index *= type_nsub(cur); cur = type_sub(cur, cast(u32) idx); }
        else if type_kind(cur) == .ARRAY { index *= type_count(cur); cur = type_elem(cur); }
        else return false, 0;
        index += idx;
    }
    return true, index;
}

// ---------------------------------------------------------------- use masks, undef vectors, fixed shuffles

SLP_USE_MASK_FIRST_ARG :: 0; SLP_USE_MASK_SECOND_ARG :: 1; SLP_USE_MASK_UNDEFS_AS_MASK :: 2;
// buildUseMask(VF, Mask, MaskArg)
slp_build_use_mask :: (vf: s64, mask: [] s32, kind: s64) -> [] bool {
    r := NewArray(vf, bool,, temp);
    for * r it.* = true;
    for m, idx: mask {
        if m == -1 { if kind == SLP_USE_MASK_UNDEFS_AS_MASK r[idx] = false; continue; }
        if kind == SLP_USE_MASK_FIRST_ARG && m < vf r[m] = false;
        else if kind == SLP_USE_MASK_SECOND_ARG && m >= vf r[m - vf] = false;
    }
    return r;
}
// isUndefVector<IsPoisonOnly>(V, UseMask)
slp_is_undef_vector :: (v: Value_Id, use_mask: [] bool = .[], poison_only := false) -> [] bool {
    n := ifx use_mask.count == 0 then 1 else use_mask.count;
    res := NewArray(n, bool,, temp);
    for * res it.* = true;
    is_t :: (x: Value_Id, poison_only: bool) -> bool { return ifx poison_only then pm_poison(x) else pm_undef_value(x); }
    if is_t(v, poison_only) return res;
    vt := vtype(v);
    if type_kind(vt) != .VECTOR { for * res it.* = false; return res; }
    if !is_const(v) {
        if use_mask.count {
            base := v;
            while is_inst(base) && inst_op(base) == .INSERTELEMENT {
                ii := base;
                base = op(ii, 0);
                if is_t(op(ii, 1), poison_only) continue;
                ok, idx := slp_element_index(ii);
                if !ok { for * res it.* = false; return res; }
                if idx < cast(u64) use_mask.count && !use_mask[idx] res[idx] = false;
            }
            if v == base { for * res it.* = false; }
            else {
                sub := NewArray(use_mask.count, bool,, temp);
                r2 := slp_is_undef_vector(base, sub, poison_only);
                for * res it.* = it.* && r2[it_index];
            }
        } else {
            for * res it.* = false;
        }
        return res;
    }
    ne := cast(s64) type_count(vt);
    for k: 0..ne-1 {
        e := cf_elt(v, cast(u64) k);
        if e != NONE && !is_t(e, poison_only) && (use_mask.count == 0 || (k < use_mask.count && !use_mask[k])) {
            if k < res.count res[k] = false;
            else res.count = res.count;   // SmallBitVector::reset beyond the size: never happens for valid masks
        }
    }
    return res;
}
all_bits :: (b: [] bool) -> bool { for b if !it return false; return true; }
any_bits :: (b: [] bool) -> bool { for b if it return true; return false; }

// isFixedVectorShuffle(VL, Mask, AC): (ok, kind, mask)
slp_is_fixed_vector_shuffle :: (vl: [] Value_Id, ac: *Assumption_Cache) -> (bool, s64, [..] s32) {
    mask: [..] s32; mask.allocator = temp;
    found := false;
    for vl if vc_is_op(it, .EXTRACTELEMENT) { found = true; break; }
    if !found return false, 0, mask;
    size: u64 = 0;
    for vl {
        if !vc_is_op(it, .EXTRACTELEMENT) continue;
        vt := vtype(op(it, 0));
        if type_kind(vt) != .VECTOR continue;
        size = max(size, type_count(vt));
    }
    vec1: Value_Id = NONE; vec2: Value_Id = NONE;
    has_non_undef := false;
    for vl {
        if !vc_is_op(it, .EXTRACTELEMENT) continue;
        x := op(it, 0);
        if pm_undef_value(x) continue;
        if is_guaranteed_not_to_be_poison(x, ac) { has_non_undef = true; break; }
    }
    UNKNOWN :: 0; SELECT :: 1; PERMUTE :: 2;
    mode := UNKNOWN;
    for k: 0..vl.count-1 array_add(*mask, -1);
    for k: 0..vl.count-1 {
        v := vl[k];
        if pm_undef_value(v) continue;
        ei := v;
        if type_kind(vtype(op(ei, 0))) == .SVECTOR return false, 0, mask;
        x := op(ei, 0);
        if all_bits(slp_is_undef_vector(x, .[], true)) continue;
        if pm_undef_value(x) {
            mask[k] = cast(s32) k;
        } else {
            if pm_undef_value(op(ei, 1)) continue;
            c := op(ei, 1);
            if vkind(c) != .C_INT return false, 0, mask;
            ap := cf_ap(c);
            if ap_uge_u64(ap, size) continue;
            mask[k] = cast(s32) ap_zext_value(ap);
        }
        if all_bits(slp_is_undef_vector(x)) && has_non_undef continue;
        if vec1 == NONE || vec1 == x vec1 = x;
        else if vec2 == NONE || vec2 == x { vec2 = x; mask[k] += cast(s32) size; }
        else return false, 0, mask;
        if mode == PERMUTE continue;
        if cast(u64) mask[k] % size != cast(u64) k { mode = PERMUTE; continue; }
        mode = SELECT;
    }
    if mode == SELECT && vec2 != NONE return true, SK_SELECT, mask;
    return true, ifx vec2 != NONE then SK_PERMUTE_TWO_SRC else SK_PERMUTE_SINGLE_SRC, mask;
}

// isValidForAlternation
slp_is_valid_for_alternation :: (opc: Opcode) -> bool { return !is_int_div_rem(opc); }

// ---------------------------------------------------------------- BinOpSameOpcodeHelper

BOP_SHL :: 1; BOP_ASHR :: 1 << 1; BOP_MUL :: 1 << 2; BOP_ADD :: 1 << 3; BOP_SUB :: 1 << 4; BOP_AND :: 1 << 5;
BOP_OR :: 1 << 6; BOP_XOR :: 1 << 7; BOP_FADD :: 1 << 8; BOP_FSUB :: 1 << 9; BOP_MAIN_OP :: 1 << 10;
BOP_ALL :: BOP_MAIN_OP | BOP_XOR | BOP_OR | BOP_AND | BOP_SUB | BOP_ADD | BOP_MUL | BOP_ASHR | BOP_SHL | BOP_FSUB | BOP_FADD;

Interchangeable_Info :: struct {
    i: Value_Id = NONE;
    mask: u32 = BOP_ALL;
    seen_before: u32 = 0;
}
// isBinOpWithConstant: (constant, operand position)
bop_with_constant :: (i: Value_Id) -> (Value_Id, u32) {
    get_c :: (v: Value_Id) -> Value_Id { if vkind(v) == .C_INT || vkind(v) == .C_FP return v; return NONE; }
    c := get_c(op(i, 1));
    if c != NONE return c, 1;
    if !slp_is_commutative(i) return NONE, 0;
    c = get_c(op(i, 0));
    if c != NONE return c, 0;
    return NONE, 0;
}
ii_try_set :: (x: *Interchangeable_Info, opcode_mask: u32, inter_mask: u32) -> bool {
    if (x.mask & inter_mask) != 0 { x.seen_before |= opcode_mask; x.mask &= inter_mask; return true; }
    return false;
}
ii_equal :: (x: *Interchangeable_Info, opc: Opcode) -> bool { return opc == inst_op(x.i) && ii_try_set(x, BOP_MAIN_OP, BOP_MAIN_OP); }
ii_get_opcode :: (x: Interchangeable_Info) -> Opcode {
    c := x.mask & x.seen_before;
    if c & BOP_MAIN_OP return inst_op(x.i);
    if c & BOP_SHL return .SHL;
    if c & BOP_ASHR return .ASHR;
    if c & BOP_MUL return .MUL;
    if c & BOP_ADD return .ADD;
    if c & BOP_SUB return .SUB;
    if c & BOP_FADD return .FADD;
    if c & BOP_FSUB return .FSUB;
    if c & BOP_AND return .AND;
    if c & BOP_OR return .OR;
    if c & BOP_XOR return .XOR;
    fatal("internal: slp: cannot find interchangeable instruction");
    return .NONE_OP;
}
ii_has_defined_opcode :: (x: Interchangeable_Info) -> bool { return (x.mask & x.seen_before) > 0; }
ii_has_candidate_opcode :: (x: Interchangeable_Info, opc: Opcode) -> bool {
    c := x.mask & x.seen_before;
    if opc == {
        case .SHL; return (c & BOP_SHL) != 0;
        case .ASHR; return (c & BOP_ASHR) != 0;
        case .MUL; return (c & BOP_MUL) != 0;
        case .ADD; return (c & BOP_ADD) != 0;
        case .SUB; return (c & BOP_SUB) != 0;
        case .AND; return (c & BOP_AND) != 0;
        case .OR; return (c & BOP_OR) != 0;
        case .XOR; return (c & BOP_XOR) != 0;
        case .FADD; return (c & BOP_FADD) != 0;
        case .FSUB; return (c & BOP_FSUB) != 0;
        case .LSHR; #through; case .FMUL; #through; case .SDIV; #through; case .UDIV; #through; case .FDIV; #through;
        case .SREM; #through; case .UREM; #through; case .FREM; return false;
    }
    fatal("internal: slp: cannot find interchangeable instruction");
    return false;
}
// InterchangeableInfo::getOperand(To): the operands of x.i rewritten for opcode `to`
ii_get_operand :: (x: Interchangeable_Info, to: Opcode) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    from := inst_op(x.i);
    if from == to { for k: 0..cast(s64) nops(x.i) - 1 array_add(*out, op(x.i, cast(u32) k)); return out; }
    c, pos := bop_with_constant(x.i);
    rhs_ty := vtype(op(x.i, pos));
    rhs: Value_Id;
    if vkind(c) == .C_FP {
        rhs = const_fp_words(rhs_ty, fp_neg(type_kind(scalar_type(vtype(c))), const_fp_value(c)));
    } else {
        v := cf_ap(c);
        bw := v.bits;
        if from == {
            case .SHL;
                if to == .ADD && ap_is_one(v) { array_add(*out, op(x.i, 0)); array_add(*out, op(x.i, 0)); return out; }
                if to == .MUL {
                    one := ap_zero(bw); ap_set_bit(*one, cast(u32) ap_zext_value(v));
                    rhs = const_int_ap(rhs_ty, one);
                } else rhs = cf_binop_identity(to, rhs_ty, true);
            case .MUL;
                if to == .SHL rhs = const_int(rhs_ty, ap_log2(v));
                else rhs = cf_binop_identity(to, rhs_ty, true);
            case .ADD; #through;
            case .SUB;
                if ap_is_zero(v) rhs = cf_binop_identity(to, rhs_ty, true);
                else rhs = const_int_ap(rhs_ty, ap_neg(v));
            case .AND;
                rhs = cf_binop_identity(to, rhs_ty, true);
            case;
                rhs = cf_binop_identity(to, rhs_ty, true);
        }
    }
    lhs := op(x.i, 1 - pos);
    if pos == 1 || !is_commutative_op(to) { array_add(*out, lhs); array_add(*out, rhs); }
    else { array_add(*out, rhs); array_add(*out, lhs); }
    return out;
}

Bop_Helper :: struct {
    main: Interchangeable_Info;
    alt: Interchangeable_Info;
}
bop_helper :: (main: Value_Id, alt: Value_Id = NONE) -> Bop_Helper {
    h: Bop_Helper;
    h.main.i = main;
    h.alt.i = alt;
    return h;
}
bop_is_valid_for_alternation :: (h: *Bop_Helper, i: Value_Id) -> bool {
    return slp_is_valid_for_alternation(inst_op(h.main.i)) && slp_is_valid_for_alternation(inst_op(i));
}
bop_initialize_alt_op :: (h: *Bop_Helper, i: Value_Id) -> bool {
    if h.alt.i != NONE return true;
    if !bop_is_valid_for_alternation(h, i) return false;
    h.alt.i = i;
    return true;
}
// BinOpSameOpcodeHelper::add
bop_add :: (h: *Bop_Helper, i: Value_Id) -> bool {
    opc := inst_op(i);
    om: u32;
    if opc == {
        case .SHL; om = BOP_SHL;
        case .ASHR; om = BOP_ASHR;
        case .MUL; om = BOP_MUL;
        case .ADD; om = BOP_ADD;
        case .SUB; om = BOP_SUB;
        case .AND; om = BOP_AND;
        case .OR; om = BOP_OR;
        case .XOR; om = BOP_XOR;
        case .FADD; om = BOP_FADD;
        case .FSUB; om = BOP_FSUB;
        case;
            return ii_equal(*h.main, opc) || (bop_initialize_alt_op(h, i) && ii_equal(*h.alt, opc));
    }
    im := om;
    c, pos := bop_with_constant(i);
    if c != NONE && vkind(c) == .C_INT {
        CAN_BE_ALL :: BOP_XOR | BOP_OR | BOP_AND | BOP_SUB | BOP_ADD | BOP_MUL | BOP_ASHR | BOP_SHL;
        v := cf_ap(c);
        if opc == {
            case .SHL;
                if ap_ult_u64(v, v.bits) im = ifx ap_is_zero(v) then cast(u32) CAN_BE_ALL else BOP_MUL | BOP_SHL;
                if ap_is_one(v) im |= BOP_ADD;
            case .MUL;
                if ap_is_one(v) im = CAN_BE_ALL;
                else if ap_is_power_of_2(v) im = BOP_MUL | BOP_SHL;
            case .ADD; #through;
            case .SUB;
                im = ifx ap_is_zero(v) then cast(u32) CAN_BE_ALL else BOP_SUB | BOP_ADD;
            case .AND;
                if ap_is_all_ones(v) im = CAN_BE_ALL;
            case .XOR;
                if ap_is_zero(v) im = BOP_XOR | BOP_OR | BOP_SUB | BOP_ADD;
            case;
                if ap_is_zero(v) im = CAN_BE_ALL;
        }
    } else if c != NONE && pos == 1 {
        im = BOP_FSUB | BOP_FADD;
    }
    return ii_try_set(*h.main, om, im) || (bop_initialize_alt_op(h, i) && ii_try_set(*h.alt, om, im));
}
bop_main_opcode :: (h: *Bop_Helper) -> Opcode { return ii_get_opcode(h.main); }
bop_has_defined_main_opcode :: (h: *Bop_Helper) -> bool { return ii_has_defined_opcode(h.main); }
bop_has_candidate_opcode :: (h: *Bop_Helper, opc: Opcode) -> bool { return ii_has_candidate_opcode(h.main, opc); }
bop_has_alt_op :: (h: *Bop_Helper) -> bool { return h.alt.i != NONE; }
bop_alt_opcode :: (h: *Bop_Helper) -> Opcode { return ifx bop_has_alt_op(h) then ii_get_opcode(h.alt) else bop_main_opcode(h); }
bop_has_defined_alt_opcode :: (h: *Bop_Helper) -> bool { return !bop_has_alt_op(h) || ii_has_defined_opcode(h.alt); }
bop_get_operand :: (h: *Bop_Helper, to: Value_Id) -> [..] Value_Id { return ii_get_operand(h.main, inst_op(to)); }

// ---------------------------------------------------------------- InstructionsState

Inst_State :: struct {
    main: Value_Id = NONE;
    alt: Value_Id = NONE;
    has_copyables: bool;
}
IS_INVALID :: Inst_State.{NONE, NONE, false};
is_valid :: inline (s: Inst_State) -> bool { return s.main != NONE && s.alt != NONE; }
is_opcode :: inline (s: Inst_State) -> Opcode { return inst_op(s.main); }
is_alt_opcode :: inline (s: Inst_State) -> Opcode { return inst_op(s.alt); }
is_alt_shuffle :: inline (s: Inst_State) -> bool { return s.main != s.alt; }

// getMatchingMainOpOrAltOp
is_matching_main_or_alt :: (s: Inst_State, i: Value_Id) -> Value_Id {
    o := inst_op(i);
    if o == inst_op(s.main) return s.main;
    if inst_op(s.main) == .SELECT && o == .ZEXT && !is_alt_shuffle(s) return s.main;
    if o == inst_op(s.alt) return s.alt;
    if !is_binary_op(o) return NONE;
    conv := bop_helper(s.main);
    if !bop_add(*conv, i) || !bop_add(*conv, s.main) return NONE;
    if is_alt_shuffle(s) && !bop_has_candidate_opcode(*conv, inst_op(s.main)) {
        ac := bop_helper(s.alt);
        if bop_add(*ac, i) && bop_add(*ac, s.alt) && bop_has_candidate_opcode(*ac, inst_op(s.alt)) return s.alt;
    }
    if bop_has_alt_op(*conv) && !is_alt_shuffle(s) return NONE;
    return ifx bop_has_alt_op(*conv) then s.alt else s.main;
}
is_shift :: (o: Opcode) -> bool { return o == .SHL || o == .LSHR || o == .ASHR; }
is_shift_op :: (s: Inst_State) -> bool { return is_shift(is_opcode(s)) && is_shift(is_alt_opcode(s)); }
is_bitwise_logic_op_state :: (s: Inst_State) -> bool { return is_bitwise_logic_op(is_opcode(s)) && is_bitwise_logic_op(is_alt_opcode(s)); }
is_mul_div_like_op :: (s: Inst_State) -> bool {
    md :: (o: Opcode) -> bool { return o == .MUL || o == .FMUL || o == .SDIV || o == .UDIV || o == .FDIV || o == .SREM || o == .UREM || o == .FREM; }
    return md(is_opcode(s)) && md(is_alt_opcode(s));
}
is_add_sub_like_op :: (s: Inst_State) -> bool {
    as :: (o: Opcode) -> bool { return o == .ADD || o == .SUB || o == .FADD || o == .FSUB; }
    return as(is_opcode(s)) && as(is_alt_opcode(s));
}
is_cmp_op :: (s: Inst_State) -> bool { return (is_opcode(s) == .ICMP || is_opcode(s) == .FCMP) && is_alt_opcode(s) == is_opcode(s); }

// isCopyableElement
is_copyable_element :: (s: Inst_State, v: Value_Id) -> bool {
    if !s.has_copyables return false;
    if is_alt_shuffle(s) || is_opcode(s) == .GEP return false;
    if !is_inst(v) return !pm_poison(v);
    if inst_block(v) != inst_block(s.main) && (!slp_is_vector_like_inst_with_const_ops(v) || !slp_is_vector_like_inst_with_const_ops(s.main)) return true;
    if inst_op(v) == inst_op(s.main) return false;
    if !is_binary_op(inst_op(v)) return true;
    conv := bop_helper(s.main);
    return !bop_add(*conv, v) || !bop_add(*conv, s.main) || bop_has_alt_op(*conv) || !bop_has_candidate_opcode(*conv, is_opcode(s));
}
// isExpandedBinOp
is_expanded_bin_op :: (s: Inst_State, v: Value_Id) -> bool {
    if is_copyable_element(s, v) return false;
    if !is_inst(v) return false;
    m := is_matching_main_or_alt(s, v);
    if inst_op(m) == .ADD && inst_op(v) == .SHL return pm_one(op(v, 1));
    return false;
}
// isExpandedOperand
is_expanded_operand :: (i: Value_Id, idx: u32) -> bool {
    if inst_op(i) == .SHL return idx == 1;
    fatal("internal: slp: unexpected opcode for an expanded operand");
    return false;
}
// isNonSchedulable
is_non_schedulable :: (s: Inst_State, v: Value_Id) -> bool {
    i := is_inst(v);
    if !s.has_copyables return !i || inst_op(v) == .PHI || slp_is_vector_like_inst_with_const_ops(v) || slp_does_not_need_to_be_scheduled(v);
    if s.main == v return false;
    if is_copyable_element(s, v) {
        return !i || inst_op(v) == .PHI || inst_block(v) != inst_block(s.main) ||
               (slp_does_not_need_to_be_scheduled(v) && !comes_before(s.main, v));
    }
    return !i || inst_op(v) == .PHI || slp_is_vector_like_inst_with_const_ops(v) || slp_does_not_need_to_be_scheduled(v);
}

// convertTo(I, S): (selected op, operands)
slp_convert_to :: (i: Value_Id, s: Inst_State) -> (Value_Id, [..] Value_Id) {
    sel := is_matching_main_or_alt(s, i);
    if sel == NONE fatal("internal: slp: cannot convert the instruction");
    if is_binary_op(inst_op(i)) {
        conv := bop_helper(i);
        return sel, bop_get_operand(*conv, sel);
    }
    ops: [..] Value_Id; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 array_add(*ops, op(i, cast(u32) k));
    return sel, ops;
}

// findInstructionWithOpcode
slp_find_instruction_with_opcode :: (vl: [] Value_Id, opc: Opcode) -> Value_Id {
    for vl {
        if pm_poison(it) continue;
        if inst_op(it) == opc return it;
    }
    return NONE;
}

// areCompatibleCmpOps
slp_are_compatible_cmp_ops :: (b0: Value_Id, b1: Value_Id, o0: Value_Id, o1: Value_Id) -> bool {
    return (slp_is_constant(b0) && slp_is_constant(o0)) || (slp_is_constant(b1) && slp_is_constant(o1)) ||
           (!is_inst(b0) && !is_inst(o0) && !is_inst(b1) && !is_inst(o1)) || b0 == o0 || b1 == o1 ||
           is_valid(slp_get_same_opcode(.[b0, o0])) || is_valid(slp_get_same_opcode(.[b1, o1]));
}
// isCmpSameOrSwapped
slp_is_cmp_same_or_swapped :: (base: Value_Id, ci: Value_Id) -> bool {
    bp := inst(base).pred; p := inst(ci).pred; sp := swapped_predicate(p);
    b0 := op(base, 0); b1 := op(base, 1); o0 := op(ci, 0); o1 := op(ci, 1);
    return (bp == p && slp_are_compatible_cmp_ops(b0, b1, o0, o1)) || (bp == sp && slp_are_compatible_cmp_ops(b0, b1, o1, o0));
}

// getIntrinsicForCallSite (ValueTracking.cpp)
get_intrinsic_for_call_site :: (c: Value_Id) -> Intrinsic_Id {
    f := call_called_function(c);
    if f == NONE return NOT_INTRINSIC;
    if glob(f).intrinsic return fn_iid(f);
    if is_local_linkage(glob(f).linkage) return NOT_INTRINSIC;
    ok, lf := tli_lookup_call(c);
    if !ok || !call_only_reads_memory(c) return NOT_INTRINSIC;
    n := tli_standard_name(lf);   // getLibFunc matches the standard name; the custom (__exp10) name does not matter
    map :: (n: string, base: string) -> bool { return n == base || n == tprint("%f", base) || n == tprint("%l", base); }
    for b: string.["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "exp", "exp2", "exp10",
                   "log", "log10", "log2", "fabs", "copysign", "floor", "ceil", "trunc", "rint", "nearbyint", "round",
                   "roundeven", "pow", "sqrt"]
        if map(n, b) return iid_by_name(tprint("llvm.%", b));
    if map(n, "fmin") return IID_MINNUM;
    if map(n, "fmax") return IID_MAXNUM;
    return NOT_INTRINSIC;
}
// getVectorIntrinsicIDForCall (VectorUtils.cpp)
get_vector_intrinsic_id_for_call :: (c: Value_Id) -> Intrinsic_Id {
    id := get_intrinsic_for_call_site(c);
    if id == NOT_INTRINSIC return NOT_INTRINSIC;
    if is_trivially_vectorizable(id) || id == IID_LIFETIME_START || id == IID_LIFETIME_END || id == IID_ASSUME ||
       id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == IID_SIDEEFFECT || id == IID_PSEUDOPROBE return id;
    return NOT_INTRINSIC;
}
// VFDatabase(*CI).getMappings(*CI) is non-empty
slp_check_no_vector_variants :: (c: Value_Id) {
    if call_has_vector_variants(c) slp_fail("calls with vector-function-abi-variant mappings (VFDatabase)");
}

// getSameOpcode(VL, TLI)
slp_get_same_opcode :: (vl: [] Value_Id) -> Inst_State {
    for vl if !is_inst(it) && !pm_poison(it) return IS_INVALID;
    first := -1;
    for vl if is_inst(it) { first = it_index; break; }
    if first < 0 return IS_INVALID;
    main := vl[first];
    inst_cnt := 0;
    for k: first..vl.count-1 if is_inst(vl[k]) inst_cnt += 1;
    if (vl.count > 2 && inst_op(main) != .PHI && inst_cnt < vl.count / 2) || (vl.count == 2 && inst_cnt < 2) return IS_INVALID;
    is_cast := is_cast_op(inst_op(main));
    is_bin := is_binary_op(inst_op(main));
    is_cmp := inst_op(main) == .ICMP || inst_op(main) == .FCMP;
    base_pred: u8 = ifx is_cmp then inst(main).pred else BAD_ICMP_PREDICATE;
    alt := main;
    opc := inst_op(main);
    alt_opc := opc;
    helper := bop_helper(main);
    swapped_compatible := false;
    if is_cmp {
        swapped_compatible = true;
        uniq: [..] u8; uniq.allocator = temp;
        uniq_ns: [..] u8; uniq_ns.allocator = temp;
        array_add(*uniq, base_pred); array_add(*uniq_ns, base_pred);
        contains :: (a: [] u8, p: u8) -> bool { for a if it == p return true; return false; }
        for v: vl {
            if !vc_is_cmp(v) { swapped_compatible = false; break; }
            cp := inst(v).pred; scp := swapped_predicate(cp);
            if !contains(uniq_ns, cp) array_add(*uniq_ns, cp);
            if !contains(uniq, cp) && !contains(uniq, scp) array_add(*uniq, cp);
        }
        if swapped_compatible swapped_compatible = uniq_ns.count > 2 && uniq.count == 2;
    }
    base_id: Intrinsic_Id = NOT_INTRINSIC;
    if inst_op(main) == .CALL {
        base_id = get_vector_intrinsic_id_for_call(main);
        slp_check_no_vector_variants(main);
        if !is_trivially_vectorizable(base_id) return IS_INVALID;
    }
    any_poison := inst_cnt != vl.count;
    for k: first..vl.count-1 {
        i := vl[k];
        if !is_inst(i) continue;
        io := inst_op(i);
        if any_poison && (is_int_div_rem(io) || io == .FDIV || io == .FREM || io == .CALL) return IS_INVALID;
        if is_bin && is_binary_op(io) {
            if bop_add(*helper, i) continue;
        } else if is_cast && is_cast_op(io) {
            ty0 := vtype(op(main, 0)); ty1 := vtype(op(i, 0));
            if ty0 == ty1 {
                if io == opc || io == alt_opc continue;
                if opc == alt_opc { alt_opc = io; alt = i; continue; }
            }
        } else if (io == .ICMP || io == .FCMP) && is_cmp {
            ty0 := vtype(op(main, 0)); ty1 := vtype(op(i, 0));
            if ty0 == ty1 {
                cp := inst(i).pred; scp := swapped_predicate(cp);
                if (vl.count == 2 || swapped_compatible) && (base_pred == cp || base_pred == scp) continue;
                if slp_is_cmp_same_or_swapped(main, i) continue;
                if main != alt {
                    if slp_is_cmp_same_or_swapped(alt, i) continue;
                } else if base_pred != cp {
                    alt = i;
                    continue;
                }
                ap := inst(alt).pred;
                if base_pred == cp || base_pred == scp || ap == cp || ap == scp continue;
            }
        } else if io == opc {
            if io == .GEP {
                if nops(i) != 2 || vtype(op(i, 0)) != vtype(op(main, 0)) return IS_INVALID;
            } else if io == .EXTRACTELEMENT {
                if !slp_is_vector_like_inst_with_const_ops(i) return IS_INVALID;
            } else if io == .LOAD {
                if !is_simple_load_store(i) || !is_simple_load_store(main) return IS_INVALID;
            } else if io == .CALL {
                if call_called_function(i) != call_called_function(main) return IS_INVALID;
                if call_num_bundles(i) > 0 slp_fail("calls with operand bundles in getSameOpcode");
                id := get_vector_intrinsic_id_for_call(i);
                if id != base_id return IS_INVALID;
                if id == NOT_INTRINSIC slp_fail("VFDatabase mappings in getSameOpcode");
            }
            continue;
        }
        return IS_INVALID;
    }
    if is_bin {
        if !bop_has_defined_main_opcode(*helper) || !bop_has_defined_alt_opcode(*helper) return IS_INVALID;
        main = slp_find_instruction_with_opcode(vl, bop_main_opcode(*helper));
        alt = slp_find_instruction_with_opcode(vl, bop_alt_opcode(*helper));
    }
    return .{main, alt, false};
}

// doesInTreeUserNeedToExtract
slp_does_in_tree_user_need_to_extract :: (scalar: Value_Id, user: Value_Id) -> bool {
    if user == NONE return false;
    o := inst_op(user);
    if o == .LOAD return op(user, 0) == scalar;
    if o == .STORE return op(user, 1) == scalar;
    if o == .CALL {
        id := get_vector_intrinsic_id_for_call(user);
        for k: 0..cast(s64) call_num_args(user) - 1
            if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) && call_arg(user, cast(u32) k) == scalar return true;
    }
    return false;
}
// isSimple(I)
slp_is_simple :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .LOAD || o == .STORE return is_simple_load_store(i);
    id := call_iid(i);
    if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMCPY_INLINE || id == IID_MEMSET_INLINE
        return !pm_one(call_arg(i, 3));
    return true;
}

// ---------------------------------------------------------------- masks and orders

// addMask(Mask, SubMask, ExtendingManyInputs)
slp_add_mask :: (mask: *[..] s32, sub: [] s32, extending_many := false) {
    if sub.count == 0 return;
    if mask.count == 0 { for sub array_add(mask, it); return; }
    nm: [..] s32; nm.allocator = temp;
    for sub array_add(*nm, -1);
    term := min(mask.count, sub.count);
    for k: 0..sub.count-1 {
        s := sub[k];
        if s == -1 || (!extending_many && (s >= term || mask.*[s] >= term)) continue;
        nm[k] = mask.*[s];
    }
    array_reset_keeping_memory(mask);
    for nm array_add(mask, it);
}
// fixupOrderingIndices
slp_fixup_ordering_indices :: (order: [] u32) {
    sz := order.count;
    unused := NewArray(sz, bool,, temp); for * unused it.* = true;
    masked := NewArray(sz, bool,, temp);
    any := false;
    for k: 0..sz-1 {
        if cast(s64) order[k] < sz unused[order[k]] = false;
        else { masked[k] = true; any = true; }
    }
    if !any return;
    idx := 0; midx := 0;
    while true {
        while midx < sz && !masked[midx] midx += 1;
        if midx >= sz break;
        while idx < sz && !unused[idx] idx += 1;
        order[midx] = cast(u32) idx;
        idx += 1; midx += 1;
    }
}
// getAltInstrMask(VL, ScalarTy, Opcode0, Opcode1)
slp_alt_instr_mask :: (vl: [] Value_Id, sty: Type_Id, opc0: Opcode, opc1: Opcode) -> [] bool {
    n := cast(s64) slp_num_elements(sty);
    m := NewArray(vl.count * n, bool,, temp);
    for lane: 0..vl.count-1 {
        if pm_poison(vl[lane]) continue;
        if inst_op(vl[lane]) == opc1 for j: 0..n-1 m[lane * n + j] = true;
    }
    return m;
}
// inversePermutation(Indices, Mask)
slp_inverse_permutation :: (indices: [] u32) -> [..] s32 {
    m: [..] s32; m.allocator = temp;
    for indices array_add(*m, -1);
    for k: 0..indices.count-1 m[indices[k]] = cast(s32) k;
    return m;
}
// reorderScalars(Scalars, Mask)
slp_reorder_scalars :: (scalars: *[..] Value_Id, mask: [] s32) {
    prev := array_copy(scalars.*,, temp);
    p := const_poison(vtype(scalars.*[0]));
    for * scalars.* it.* = p;
    for k: 0..prev.count-1 if mask[k] != -1 scalars.*[mask[k]] = prev[k];
}

// ---------------------------------------------------------------- scheduling predicates

// areAllOperandsNonInsts
slp_are_all_operands_non_insts :: (v: Value_Id) -> bool {
    if !is_inst(v) return true;
    if may_have_non_def_use_dependency(v) return false;
    for k: 0..cast(s64) nops(v) - 1 {
        o := op(v, cast(u32) k);
        if !is_inst(o) continue;
        if inst_op(o) != .PHI && inst_block(o) == inst_block(v) return false;
    }
    return true;
}
// isUsedOutsideBlock
slp_is_used_outside_block :: (v: Value_Id) -> bool {
    if !is_inst(v) return true;
    if may_read_or_write_memory(v) || has_n_uses_or_more(v, SLP_USES_LIMIT) return false;
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) continue;
        if inst_block(usr) == inst_block(v) && inst_op(usr) != .PHI return false;
    }
    return true;
}
// doesNotNeedToBeScheduled
slp_does_not_need_to_be_scheduled :: (v: Value_Id) -> bool { return slp_are_all_operands_non_insts(v) && slp_is_used_outside_block(v); }
// doesNotNeedToSchedule(VL)
slp_does_not_need_to_schedule :: (vl: [] Value_Id) -> bool {
    if vl.count == 0 return false;
    a := true; for vl if !slp_is_used_outside_block(it) { a = false; break; }
    if a return true;
    for vl if !slp_are_all_operands_non_insts(it) return false;
    return true;
}
