// InstCombine: vector and aggregate operations. A port of llvm/lib/Transforms/InstCombine/InstCombineVectorOps.cpp
// (complete, in LLVM's order): cheapToScalarize, scalarizePHI, foldBitcastExtElt, findDemandedElts*,
// getPreferredVectorIndex, visitExtractElementInst, collectSingleShuffleElements, replaceExtractElements,
// collectShuffleElements, foldAggregateConstructionIntoAggregateReuse, visitInsertValueInst,
// isShuffleEquivalentToSelect, foldInsSequenceIntoSplat, foldInsEltIntoSplat, foldInsEltIntoIdentityShuffle,
// hoistInsEltConst, foldConstantInsEltIntoShuffle, narrowInsElt, foldTruncInsEltPair, visitInsertElementInst,
// canEvaluateShuffled, buildNew, evaluateInDifferentElementOrder, isShuffleExtractingFromLHS, getAlternateBinop,
// foldSelectShuffleOfSelectShuffle, foldSelectShuffleWith1Binop, canonicalizeInsertSplat, foldSelectShuffle,
// foldTruncShuffle, narrowVectorSelect, foldShuffleOfUnaryOps, foldCastShuffle, foldIdentityExtractShuffle,
// foldShuffleWithInsert, foldIdentityPaddedShuffles, simplifyBinOpSplats, visitShuffleVectorInst,
// foldExtractionOfVectorDeinterleave.
// Masks are `[..] s32` copies with -1 = poison (the IR keeps them as u32 with 0xFFFFFFFF in ir.u32_pool, which can
// move while new shuffles are created).

MASK_POISON :: -1;
IID_STEPVECTOR :: #run iid_by_name("llvm.stepvector");

// ShuffleVectorInst::getShuffleMask (a copy)
shuf_mask :: (sv: Value_Id) -> [..] s32 {
    m := shuffle_mask(sv);
    r: [..] s32; r.allocator = temp;
    for m array_add(*r, ifx it == 0xFFFF_FFFF then cast(s32) -1 else cast(s32) it);
    return r;
}
mask_to_u32 :: (m: [] s32) -> [] u32 {
    r := NewArray(m.count, u32,, allocator = temp);
    for m r[it_index] = ifx it < 0 then 0xFFFF_FFFF else cast(u32) it;
    return r;
}
// new ShuffleVectorInst(V1, V2, Mask) (unlinked)
create_shuffle_s32 :: (v1: Value_Id, v2: Value_Id, m: [] s32) -> Value_Id { return create_shuffle(v1, v2, mask_to_u32(m)); }
icb_shuffle_s32 :: (v1: Value_Id, v2: Value_Id, m: [] s32, name: string = "") -> Value_Id { return icb_shuffle(v1, v2, mask_to_u32(m), name); }
// ShuffleVectorInst::getMaskValue
sv_mask_value :: (sv: Value_Id, k: u64) -> s32 { x := shuffle_mask(sv)[k]; return ifx x == 0xFFFF_FFFF then cast(s32) -1 else cast(s32) x; }
// llvm::getSplatIndex(Mask)
get_splat_index :: (mask: [] s32) -> s32 {
    splat: s32 = -1;
    for mask {
        if it == -1 continue;
        if splat != -1 && splat != it return -1;
        splat = it;
    }
    return splat;
}
is_fixed_vector :: (t: Type_Id) -> bool { return type_kind(t) == .VECTOR; }
vec_count :: (t: Type_Id) -> u64 { return type_count(t); }
// m_ConstantInt(): a ConstantInt (scalar here; vector-typed ConstantInt splats are not ConstantInts for indices)
is_constant_int :: (v: Value_Id) -> bool { return vkind(v) == .C_INT && !is_vector_type(vtype(v)); }
const_zext :: (v: Value_Id) -> u64 { return ap_zext_value(const_ap(v)); }

// cheapToScalarize
cheap_to_scalarize :: (v: Value_Id, ei: Value_Id) -> bool {
    cei := is_constant_int(ei);
    if is_const(v) return cei || get_splat_value(v) != NONE;
    if cei && call_iid(v) == IID_STEPVECTOR return ap_ult_u64(const_ap(ei), vec_count(vtype(v)));
    if is_inst(v) && inst_op(v) == .INSERTELEMENT && is_constant_int(op(v, 2)) return cei;
    if is_inst(v) && inst_op(v) == .LOAD && has_one_use(v) return true;
    if is_inst(v) && inst_op(v) == .FNEG && has_one_use(v) return true;
    if is_inst(v) && is_binary_op(inst_op(v)) && has_one_use(v)
        if cheap_to_scalarize(op(v, 0), ei) || cheap_to_scalarize(op(v, 1), ei) return true;
    if is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP) && has_one_use(v)
        if cheap_to_scalarize(op(v, 0), ei) || cheap_to_scalarize(op(v, 1), ei) return true;
    return false;
}

// BinaryOperator::CreateWithCopiedFlags / UnaryOperator / CmpInst
create_binop_copied :: (opc: Opcode, a: Value_Id, b: Value_Id, src: Value_Id) -> Value_Id {
    r := create_binop(opc, a, b);
    copy_ir_flags(r, src);
    return r;
}

// scalarizePHI
ic_scalarize_phi :: (ei: Value_Id, pn: Value_Id) -> Value_Id {
    extracts: [..] Value_Id; extracts.allocator = temp;
    phi_user: Value_Id = NONE;
    u := ir.v_first_use[pn];
    while u != NONE {
        us := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(us) && inst_op(us) == .EXTRACTELEMENT {
            if op(ei, 1) == op(us, 1) array_add(*extracts, us);
            else return NONE;
        } else if phi_user == NONE phi_user = us;
        else return NONE;
    }
    if phi_user == NONE return NONE;
    if !has_one_use(phi_user) || first_user(phi_user) != pn || !is_binary_operator(phi_user) || !cheap_to_scalarize(phi_user, op(ei, 1)) return NONE;
    sp := ic_insert_new_inst_with(create_phi(vtype(ei), nops(pn)), pn);
    seen_bb: [..] Value_Id; seen_bb.allocator = temp;
    seen_val: [..] Value_Id; seen_val.allocator = temp;
    for k: 0..cast(s64) nops(pn) - 1 {
        in_val := op(pn, cast(u32) k);
        in_bb := phi_block(pn, cast(u32) k);
        elt := op(ei, 1);
        existing: Value_Id = NONE;
        for seen_bb if it == in_bb { existing = seen_val[it_index]; break; }
        if existing != NONE { phi_add_incoming(sp, existing, in_bb); continue; }
        scalar: Value_Id;
        if in_val == phi_user {
            b0 := phi_user;
            op_id: u32 = ifx op(b0, 0) == pn then cast(u32) 1 else 0;
            ee := create_extract_element(op(b0, op_id), elt);
            set_name(ee, tprint("%.Elt", vname(op(b0, op_id))));
            o := ic_insert_new_inst_with(ee, b0);
            first := ifx op(b0, 0) == pn then sp else o;
            second := ifx op(b0, 0) == pn then o else sp;
            scalar = ic_insert_new_inst_with(create_binop_copied(inst_op(b0), first, second, b0), b0);
        } else {
            nei := create_extract_element(in_val, elt);
            if is_inst(in_val) && !is_phi(in_val) {
                nx := inst(in_val).next;
                if nx == NONE fatal("internal: scalarizePHI: no position after the incoming value");
                scalar = ic_insert_new_inst_with(nei, nx);
            } else {
                pos := block_first_insertion_pt(in_bb);
                if pos == NONE fatal("internal: scalarizePHI: no insertion point");
                scalar = ic_insert_new_inst_with(nei, pos, true);
            }
        }
        array_add(*seen_bb, in_bb); array_add(*seen_val, scalar);
        phi_add_incoming(sp, scalar, in_bb);
    }
    for extracts {
        ic_replace_inst_uses_with(it, sp);
        wl_add(it);
    }
    return ei;
}

// foldBitcastExtElt
ic_fold_bitcast_ext_elt :: (ext: Value_Id) -> Value_Id {
    vec := op(ext, 0);
    if opr_code(vec) != .BITCAST return NONE;
    x := op(vec, 0);
    okc, ext_index := pm_constant_int_u64(op(ext, 1));
    if !okc || !is_constant_int(op(ext, 1)) return NONE;
    vt := vtype(vec);
    num_elts := vec_count(vt);
    dest_ty := vtype(ext);
    dest_width, _ := prim_size_bits(dest_ty);
    big := dl.big_endian;
    if is_int_type(vtype(x)) {
        if big ext_index = num_elts - 1 - ext_index;
        shift := ext_index * dest_width;
        xw, _ := prim_size_bits(vtype(x));
        if (shift == 0 || ic_is_desirable_int_type(cast(u32) xw)) && has_one_use(vec) {
            xv := x;
            if shift xv = icb_lshr(xv, const_int_of(vtype(xv), shift), "extelt.offset");
            if is_fp_type(dest_ty) {
                t := icb_trunc(xv, type_int(dest_width));
                return create_cast(.BITCAST, t, dest_ty);
            }
            return create_cast(.TRUNC, xv, dest_ty);
        }
    }
    if !is_vector_type(vtype(x)) return NONE;
    src_ty := vtype(x);
    num_src := vec_count(src_ty);
    if num_src == num_elts {
        e := find_scalar_element(x, cast(u32) ext_index);
        if e != NONE return create_cast(.BITCAST, e, dest_ty);
    }
    if num_src < num_elts {
        if !is_inst(x) || inst_op(x) != .INSERTELEMENT || !is_constant_int(op(x, 2)) return NONE;
        vv := op(x, 0); scalar := op(x, 1); ins_index := const_zext(op(x, 2));
        ratio := num_elts / num_src;
        if ext_index / ratio != ins_index {
            if has_one_use(x) && has_one_use(vec) {
                nbc := icb_cast(.BITCAST, vv, vt);
                return create_extract_element(nbc, op(ext, 1));
            }
            return NONE;
        }
        chunk := ext_index % ratio;
        if big chunk = ratio - 1 - chunk;
        need_src_bc := is_fp_type(scalar_type(src_ty));
        need_dest_bc := is_fp_type(dest_ty);
        if need_src_bc && need_dest_bc return NONE;
        src_width := cast(u64) type_bits(scalar_type(src_ty));
        sh := chunk * dest_width;
        if !has_one_use(x) || !has_one_use(vec)
            if need_src_bc || need_dest_bc return NONE;
        s := scalar;
        if need_src_bc s = icb_cast(.BITCAST, s, type_int(src_width));
        if sh {
            if !has_one_use(vec) return NONE;
            s = icb_lshr(s, const_int_of(vtype(s), sh));
        }
        if need_dest_bc return create_cast(.BITCAST, icb_trunc(s, type_int(dest_width)), dest_ty);
        return create_cast(.TRUNC, s, dest_ty);
    }
    return NONE;
}

// findDemandedEltsBySingleUser
find_demanded_elts_by_single_user :: (v: Value_Id, user: Value_Id, used: *APInt) -> bool {
    vw := vec_count(vtype(v));
    o := inst_op(user);
    if o == .EXTRACTELEMENT {
        idx := op(user, 1);
        if is_constant_int(idx) && ap_ult_u64(const_ap(idx), vw) { ap_set_bit(used, cast(u32) const_zext(idx)); return true; }
    } else if o == .SHUFFLEVECTOR {
        n := vec_count(vtype(user));
        for i: 0..cast(s64) n - 1 {
            mv := cast,no_check(u32) sv_mask_value(user, cast(u64) i);   // -1 -> 0xFFFFFFFF
            if mv == 0xFFFF_FFFF || cast(u64) mv >= 2 * vw continue;
            if op(user, 0) == v && cast(u64) mv < vw ap_set_bit(used, mv);
            if op(user, 1) == v && cast(u64) mv >= vw && cast(u64) mv < 2 * vw ap_set_bit(used, mv - cast(u32) vw);
        }
        return true;
    }
    return false;
}
// findDemandedEltsByAllUsers
find_demanded_elts_by_all_users :: (v: Value_Id) -> APInt {
    vw := cast(u32) vec_count(vtype(v));
    used := ap_zero(vw);
    u := ir.v_first_use[v];
    while u != NONE {
        us := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(us) {
            if !find_demanded_elts_by_single_user(v, us, *used) return ap_all_ones(vw);
        } else { used = ap_all_ones(vw); break; }
        if ap_is_all_ones(used) break;
    }
    return used;
}

// getPreferredVectorIndex
get_preferred_vector_index :: (c: Value_Id) -> Value_Id {
    a := const_ap(c);
    if a.bits == 64 || ap_active_bits(a) > 64 return NONE;
    return const_int_ap(ir.t_i64, ap_zext_or_trunc(a, 64));
}

// visitExtractElementInst
ic_visit_extract_element :: (ei: Value_Id) -> Value_Id {
    src := op(ei, 0);
    index := op(ei, 1);
    v := simplify_extract_element_inst(src, index, ic_q(ei));
    if v != NONE return ic_replace_inst_uses_with(ei, v);
    if is_inst(src) && inst_op(src) == .SELECT {
        if is_int_type(vtype(op(src, 0))) && is_const(index) {
            r := ic_fold_op_into_select(ei, src); if r != NONE return r;
        }
    }
    index_c := is_constant_int(index);
    has_known_valid := false;
    if index_c {
        ni := get_preferred_vector_index(index);
        if ni != NONE return ic_replace_operand(ei, 1, ni);
        vt := vtype(src);
        n := vec_count(vt);
        has_known_valid = ap_ult_u64(const_ap(index), n);
        if call_iid(src) == IID_STEPVECTOR && ap_ult_u64(const_ap(index), n) {
            ty := vtype(ei);
            bw := type_int_width(ty);
            if ap_active_bits(const_ap(index)) <= bw return ic_replace_inst_uses_with(ei, const_int_ap(ty, ap_zext_or_trunc(const_ap(index), bw)));
            return NONE;
        }
        if is_fixed_vector(vt) && ap_uge_u64(const_ap(index), n) return NONE;
        r := ic_fold_bitcast_ext_elt(ei); if r != NONE return r;
        if is_phi(src) { r = ic_scalarize_phi(ei, src); if r != NONE return r; }
    }
    if call_iid(src) == IID_VECTOR_EXTRACT && pm_zero(call_arg(src, 1)) return create_extract_element(call_arg(src, 0), index);
    if is_inst(src) && inst_op(src) == .FNEG && cheap_to_scalarize(src, index) {
        e := icb_extract_element(op(src, 0), index);
        r := new_inst(.FNEG, vtype(e), 1);
        set_op(r, 0, e);
        copy_ir_flags(r, src);
        return r;
    }
    if is_inst(src) && is_binary_op(inst_op(src)) && cheap_to_scalarize(src, index) &&
       (has_known_valid || is_safe_to_speculate_binop_variable_replaced(src)) {
        e0 := icb_extract_element(op(src, 0), index);
        e1 := icb_extract_element(op(src, 1), index);
        return create_binop_copied(inst_op(src), e0, e1, src);
    }
    if is_inst(src) && (inst_op(src) == .ICMP || inst_op(src) == .FCMP) && cheap_to_scalarize(src, index) {
        e0 := icb_extract_element(op(src, 0), index);
        e1 := icb_extract_element(op(src, 1), index);
        r := ifx inst_op(src) == .ICMP then create_icmp(inst(src).pred, e0, e1) else create_fcmp(inst(src).pred, e0, e1);
        copy_ir_flags(r, src);
        return r;
    }
    if is_inst(src) {
        o := inst_op(src);
        if o == .INSERTELEMENT {
            if is_const(op(src, 2)) && index_c return ic_replace_operand(ei, 0, op(src, 0));
        } else if o == .GEP {
            vt := vtype(src);
            idx_val: u64 = ifx index_c then const_zext(index) else 0;
            if index_c && idx_val < vec_count(vt) && has_one_use(src) {
                vector_ops := 0;
                for k: 0..cast(s64) nops(src) - 1 if is_vector_type(vtype(op(src, cast(u32) k))) vector_ops += 1;
                if vector_ops == 1 {
                    np := op(src, 0);
                    if is_vector_type(vtype(np)) np = icb_extract_element(np, index);
                    nops_: [..] Value_Id; nops_.allocator = temp;
                    for k: 1..cast(s64) nops(src) - 1 {
                        x := op(src, cast(u32) k);
                        if is_vector_type(vtype(x)) array_add(*nops_, icb_extract_element(x, index));
                        else array_add(*nops_, x);
                    }
                    ng := create_gep(inst(src).ty2, np, nops_);
                    gep_set_nw(ng, gep_nw_bits(src));
                    return ng;
                }
            }
        } else if o == .SHUFFLEVECTOR {
            m := shuf_mask(src);
            splat := get_splat_index(m);
            if splat == 0 return create_extract_element(op(src, 0), const_int(ir.t_i64, 0));
            if is_fixed_vector(vtype(src)) {
                have := false; src_idx: s64;
                if splat != -1 { have = true; src_idx = splat; }
                else if is_constant_int(index) { have = true; src_idx = sv_mask_value(src, const_zext(index)); }
                if have {
                    lhs_width := cast(s64) vec_count(vtype(op(src, 0)));
                    if src_idx < 0 return ic_replace_inst_uses_with(ei, const_poison(vtype(ei)));
                    s: Value_Id;
                    if src_idx < lhs_width s = op(src, 0);
                    else { src_idx -= lhs_width; s = op(src, 1); }
                    return create_extract_element(s, const_int(ir.t_i64, cast(u64) src_idx));
                }
            }
        } else if is_cast_op(o) {
            if has_one_use(src) && o != .BITCAST && (inst_block(ei) == inst_block(src) || is_constant_int(index)) {
                ee := icb_extract_element(op(src, 0), index);
                return create_cast(o, ee, vtype(ei));
            }
        }
    }
    if index_c {
        vt := vtype(src);
        n := cast(u32) vec_count(vt);
        if is_fixed_vector(vt) && n != 1 {
            if has_one_use(src) {
                poison := ap_zero(n);
                de := ap_zero(n);
                ap_set_bit(*de, cast(u32) const_zext(index));
                r := ic_simplify_demanded_vector_elts(src, de, *poison);
                if r != NONE return ic_replace_operand(ei, 0, r);
            } else {
                de := find_demanded_elts_by_all_users(src);
                if !ap_is_all_ones(de) {
                    poison := ap_zero(n);
                    r := ic_simplify_demanded_vector_elts(src, de, *poison, 0, true);
                    if r != NONE && r != src {
                        wl_add_value(src);
                        rauw_with_metadata(src, r);
                        return ei;
                    }
                }
            }
        }
    }
    return NONE;
}

// collectSingleShuffleElements
collect_single_shuffle_elements :: (v: Value_Id, lhs: Value_Id, rhs: Value_Id, mask: *[..] s32) -> bool {
    n := cast(s64) vec_count(vtype(v));
    if pm_poison(v) {
        mask.count = 0;
        for 0..n-1 array_add(mask, -1);
        return true;
    }
    if v == lhs { for i: 0..n-1 array_add(mask, cast(s32) i); return true; }
    if v == rhs { for i: 0..n-1 array_add(mask, cast(s32)(i + n)); return true; }
    if is_inst(v) && inst_op(v) == .INSERTELEMENT {
        vec_op := op(v, 0); scalar_op := op(v, 1); idx_op := op(v, 2);
        if !is_constant_int(idx_op) return false;
        inserted := cast(s64) const_zext(idx_op);
        if vkind(scalar_op) == .C_POISON {
            if collect_single_shuffle_elements(vec_op, lhs, rhs, mask) { mask.*[inserted] = -1; return true; }
        } else if is_inst(scalar_op) && inst_op(scalar_op) == .EXTRACTELEMENT {
            if is_constant_int(op(scalar_op, 1)) {
                extracted := cast(s64) const_zext(op(scalar_op, 1));
                num_lhs := cast(s64) vec_count(vtype(lhs));
                if op(scalar_op, 0) == lhs || op(scalar_op, 0) == rhs {
                    if collect_single_shuffle_elements(vec_op, lhs, rhs, mask) {
                        if op(scalar_op, 0) == lhs mask.*[inserted % n] = cast(s32) extracted;
                        else mask.*[inserted % n] = cast(s32)(extracted + num_lhs);
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

// replaceExtractElements
replace_extract_elements :: (ins: Value_Id, ext: Value_Id) -> bool {
    ins_ty := vtype(ins); ext_ty := vtype(op(ext, 0));
    num_ins := vec_count(ins_ty); num_ext := vec_count(ext_ty);
    if type_elem(ins_ty) != type_elem(ext_ty) || num_ext >= num_ins return false;
    ext_vec := op(ext, 0);
    k := vkind(ext_vec);
    if k == .C_ZERO || k == .C_DATA || k == .C_INT || k == .C_FP || k == .C_NULL || k == .C_UNDEF || k == .C_POISON return false;   // ConstantData
    em: [..] s32; em.allocator = temp;
    for i: 0..cast(s64) num_ext - 1 array_add(*em, cast(s32) i);
    for i: cast(s64) num_ext..cast(s64) num_ins - 1 array_add(*em, -1);
    ext_inst := ifx is_inst(ext_vec) then ext_vec else NONE;
    ins_block := ifx ext_inst != NONE && !is_phi(ext_inst) then inst_block(ext_inst) else inst_block(ext);
    if ins_block != inst_block(ins) return false;
    if has_one_use(ins) && inst_op(first_user(ins)) == .INSERTELEMENT return false;
    wide := create_shuffle_s32(ext_vec, NONE, em);
    if ext_inst != NONE && !is_phi(ext_inst) {
        inst_insert_after(wide, ext_inst);   // insertAfter: does not adopt debug records
        ic_reinsert_name(wide);
    } else {
        pos := block_first_insertion_pt(inst_block(ext));
        ic_insert_new_inst_with(wide, pos, true);
    }
    if ext_inst != NONE set_metadata(wide, 0, get_metadata(ext_inst, 0));
    else set_metadata(wide, 0, NONE);   // DebugLoc::getCompilerGenerated()
    u := ir.v_first_use[ext_vec];
    while u != NONE {
        us := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(us) || inst_op(us) != .EXTRACTELEMENT || inst_block(us) != inst_block(wide) continue;
        ne := create_extract_element(wide, op(us, 1));
        ic_insert_new_inst_with(ne, us);
        ic_replace_inst_uses_with(us, ne);
        wl_add(us);
    }
    return true;
}

// collectShuffleElements: (LHS, RHS)
collect_shuffle_elements :: (v: Value_Id, mask: *[..] s32, permitted_rhs: Value_Id, rerun: *bool) -> (Value_Id, Value_Id) {
    n := cast(s64) vec_count(vtype(v));
    if pm_poison(v) {
        mask.count = 0;
        for 0..n-1 array_add(mask, -1);
        return ifx permitted_rhs != NONE then const_poison(vtype(permitted_rhs)) else v, NONE;
    }
    if vkind(v) == .C_ZERO {
        mask.count = 0;
        for 0..n-1 array_add(mask, 0);
        return v, NONE;
    }
    if is_inst(v) && inst_op(v) == .INSERTELEMENT {
        vec_op := op(v, 0); scalar_op := op(v, 1); idx_op := op(v, 2);
        if is_inst(scalar_op) && inst_op(scalar_op) == .EXTRACTELEMENT {
            e := scalar_op;
            if is_constant_int(op(e, 1)) && is_constant_int(idx_op) {
                extracted := cast(s64) const_zext(op(e, 1));
                inserted := cast(s64) const_zext(idx_op);
                if op(e, 0) == permitted_rhs || permitted_rhs == NONE {
                    rhs := op(e, 0);
                    l, r := collect_shuffle_elements(vec_op, mask, rhs, rerun);
                    if vtype(l) != vtype(rhs) {
                        if replace_extract_elements(v, e) rerun.* = true;
                        for i: 0..n-1 mask.*[i] = cast(s32) i;
                        return v, NONE;
                    }
                    num_lhs := cast(s64) vec_count(vtype(rhs));
                    mask.*[inserted % n] = cast(s32)(num_lhs + extracted);
                    return l, rhs;
                }
                if vec_op == permitted_rhs {
                    num_lhs := cast(s64) vec_count(vtype(op(e, 0)));
                    for i: 0..n-1 array_add(mask, cast(s32) ifx i == inserted then extracted else num_lhs + i);
                    return op(e, 0), permitted_rhs;
                }
                if vtype(op(e, 0)) == vtype(permitted_rhs) && collect_single_shuffle_elements(v, op(e, 0), permitted_rhs, mask)
                    return op(e, 0), permitted_rhs;
            }
        }
    }
    for i: 0..n-1 array_add(mask, cast(s32) i);
    return v, NONE;
}


// foldAggregateConstructionIntoAggregateReuse
ic_fold_aggregate_construction_into_aggregate_reuse :: (orig: Value_Id) -> Value_Id {
    agg_ty := vtype(orig);
    num: u64 = ifx type_kind(agg_ty) == .STRUCT then cast(u64) type_nsub(agg_ty) else type_count(agg_ty);
    if num > 2 return NONE;
    NOT_FOUND :: cast(Value_Id) 0xFFFF_FFFE;
    MISMATCH :: cast(Value_Id) 0xFFFF_FFFD;
    elts: [2] Value_Id;
    elts[0] = NOT_FOUND; elts[1] = NOT_FOUND;
    know_all :: (elts: [2] Value_Id, num: u64) -> bool { for k: 0..cast(s64) num - 1 if elts[k] == NOT_FOUND return false; return true; }
    depth := 0;
    depth_limit := 2 * cast(s64) num;
    cur := orig;
    while depth < depth_limit && cur != NONE && !know_all(elts, num) {
        iv := op(cur, 1);
        if !is_inst(iv) return NONE;
        if inst(cur).nidx != 1 return NONE;
        idx := ir.u32_pool[inst(cur).idx];
        if elts[idx] == NOT_FOUND elts[idx] = iv;
        nxt := op(cur, 0);
        cur = ifx is_inst(nxt) && inst_op(nxt) == .INSERTVALUE then nxt else NONE;
        depth += 1;
    }
    if !know_all(elts, num) return NONE;
    elt_defined_in_use_bb := false;
    find_source_aggregate :: (elt_in: Value_Id, idx: u32, use_bb: Value_Id, pred_bb: Value_Id, agg_ty: Type_Id, in_use_bb: *bool) -> Value_Id {
        elt := elt_in;
        if use_bb != NONE && pred_bb != NONE {
            t := do_phi_translation(elt, use_bb, pred_bb);
            elt = ifx is_inst(t) then t else NONE;
            if elt != NONE && inst_block(elt) == use_bb in_use_bb.* = true;
        }
        if elt == NONE || inst_op(elt) != .EXTRACTVALUE return NOT_FOUND;
        sa := op(elt, 0);
        if vtype(sa) != agg_ty return MISMATCH;
        if inst(elt).nidx != 1 || idx != ir.u32_pool[inst(elt).idx] return MISMATCH;
        return sa;
    }
    find_common :: (elts: [2] Value_Id, num: u64, use_bb: Value_Id, pred_bb: Value_Id, agg_ty: Type_Id, in_use_bb: *bool) -> Value_Id {
        sa := NOT_FOUND;
        for k: 0..cast(s64) num - 1 {
            se := find_source_aggregate(elts[k], cast(u32) k, use_bb, pred_bb, agg_ty, in_use_bb);
            if se == NOT_FOUND || se == MISMATCH return se;
            if sa == NOT_FOUND { sa = se; continue; }
            if se != sa return MISMATCH;
        }
        return sa;
    }
    sa := find_common(elts, num, NONE, NONE, agg_ty, *elt_defined_in_use_bb);
    if sa != NOT_FOUND {
        if sa == MISMATCH return NONE;
        return ic_replace_inst_uses_with(orig, sa);
    }
    use_bb: Value_Id = NONE;
    for k: 0..cast(s64) num - 1 {
        bb := inst_block(elts[k]);
        if use_bb == NONE { use_bb = bb; continue; }
        if use_bb != bb return NONE;
    }
    if use_bb == NONE return NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(use_bb, *preds);
    if preds.count == 0 return NONE;
    if preds.count > 64 return NONE;
    sa_keys: [..] Value_Id; sa_keys.allocator = temp;
    sa_vals: [..] Value_Id; sa_vals.allocator = temp;
    found_src := false;
    for p: preds {
        if pr_contains(sa_keys, p) continue;
        array_add(*sa_keys, p); array_add(*sa_vals, NONE);
        s := find_common(elts, num, use_bb, p, agg_ty, *elt_defined_in_use_bb);
        if s != NOT_FOUND && s != MISMATCH {
            found_src = true;
            sa_vals[sa_vals.count - 1] = s;
        } else {
            if inst_op(block_terminator(p)) != .BR return NONE;
        }
    }
    if !found_src return NONE;
    orig_bb := inst_block(orig);
    for sa_keys {
        if sa_vals[it_index] != NONE continue;
        if elt_defined_in_use_bb return NONE;
        if use_bb != orig_bb return NONE;
        const_agg := true;
        for k: 0..cast(s64) num - 1 if !is_const(do_phi_translation(elts[k], use_bb, it)) { const_agg = false; break; }
        if const_agg return NONE;
    }
    for p: sa_keys {
        if sa_vals[it_index] != NONE continue;
        icb_set_insert_point(block_terminator(p));
        v := const_poison(agg_ty);
        for k: 0..cast(s64) num - 1 v = icb_insert_value(v, do_phi_translation(elts[k], use_bb, p), .[cast(u32) k]);
        sa_vals[it_index] = v;
    }
    saved := ic.b;
    defer ic.b = saved;
    irb_set_at(*ic.b, use_bb, block_first_non_phi(use_bb), true);
    pn := icb_phi(agg_ty, cast(u32) preds.count, tprint("%.merged", vname(orig)));
    for p: preds {
        v: Value_Id = NONE;
        for sa_keys if it == p { v = sa_vals[it_index]; break; }
        phi_add_incoming(pn, v, p);
    }
    return ic_replace_inst_uses_with(orig, pn);
}

// visitInsertValueInst
ic_visit_insert_value :: (i: Value_Id) -> Value_Id {
    first_idx := inst_indices_copy(i);
    v := simplify_insert_value_inst(op(i, 0), op(i, 1), first_idx, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    redundant := false;
    x := i;
    depth := 0;
    while has_one_use(x) && depth < 10 {
        u := first_user(x);
        if !is_inst(u) || inst_op(u) != .INSERTVALUE || op(u, 0) != x break;
        same := inst(u).nidx == cast(u32) first_idx.count;
        if same for first_idx if ir.u32_pool[inst(u).idx + cast(u32) it_index] != it { same = false; break; }
        if same { redundant = true; break; }
        x = u;
        depth += 1;
    }
    if redundant return ic_replace_inst_uses_with(i, op(i, 0));
    r := ic_fold_aggregate_construction_into_aggregate_reuse(i); if r != NONE return r;
    return NONE;
}

// ---------------------------------------------------------------- insertelement

// ShuffleVectorInst predicates on an instruction (the static mask helpers are svm_* in tti.jai)
sv_changes_length :: (sv: Value_Id) -> bool { return vec_count(vtype(op(sv, 0))) != vec_count(vtype(sv)); }
sv_is_select :: (sv: Value_Id) -> bool { m := shuf_mask(sv); return !sv_changes_length(sv) && svm_is_select(m, m.count); }
sv_is_zero_elt_splat_i :: (sv: Value_Id) -> bool { m := shuf_mask(sv); return !sv_changes_length(sv) && svm_is_zero_elt_splat(m, m.count); }
sv_is_identity_i :: (sv: Value_Id) -> bool {
    if type_kind(vtype(sv)) == .SVECTOR return false;
    m := shuf_mask(sv);
    return !sv_changes_length(sv) && svm_is_identity(m, m.count);
}
// isIdentityMaskImpl
identity_mask_impl :: (m: [] s32, n: s64) -> bool { return svm_is_identity_no_checks(m, n); }
sv_is_identity_with_padding :: (sv: Value_Id) -> bool {
    if type_kind(vtype(sv)) == .SVECTOR return false;
    nop := cast(s64) vec_count(vtype(op(sv, 0))); nm := cast(s64) vec_count(vtype(sv));
    if nm <= nop return false;
    m := shuf_mask(sv);
    if !identity_mask_impl(m, nop) return false;
    for i: nop..nm-1 if m[i] != -1 return false;
    return true;
}
sv_is_identity_with_extract :: (sv: Value_Id) -> bool {
    if type_kind(vtype(sv)) == .SVECTOR return false;
    nop := cast(s64) vec_count(vtype(op(sv, 0))); nm := cast(s64) vec_count(vtype(sv));
    if nm >= nop return false;
    return identity_mask_impl(shuf_mask(sv), nop);
}
sv_is_concat :: (sv: Value_Id) -> bool {
    if pm_undef(op(sv, 0)) || pm_undef(op(sv, 1)) return false;
    if type_kind(vtype(sv)) == .SVECTOR return false;
    nop := cast(s64) vec_count(vtype(op(sv, 0))); nm := cast(s64) vec_count(vtype(sv));
    if nm != nop * 2 return false;
    return identity_mask_impl(shuf_mask(sv), nm);
}
// ShuffleVectorInst::commuteShuffleMask
commute_shuffle_mask :: (m: *[..] s32, n: s64) {
    for * m.* {
        if it.* == -1 continue;
        if it.* < n it.* += cast(s32) n; else it.* -= cast(s32) n;
    }
}

// isShuffleEquivalentToSelect
is_shuffle_equivalent_to_select :: (sv: Value_Id) -> bool {
    if type_kind(vtype(op(sv, 0))) == .SVECTOR return false;
    m := shuf_mask(sv);
    vs := cast(s64) vec_count(vtype(op(sv, 0)));
    if m.count != vs return false;
    for m if it != -1 && it != it_index && it != it_index + vs return false;
    return true;
}

// foldInsSequenceIntoSplat
fold_ins_sequence_into_splat :: (ins: Value_Id) -> Value_Id {
    if has_one_use(ins) && inst_op(first_user(ins)) == .INSERTELEMENT return NONE;
    vt := vtype(ins);
    if type_kind(vt) == .SVECTOR return NONE;
    n := cast(s64) vec_count(vt);
    if n == 1 return NONE;
    splat_val := op(ins, 1);
    cur := ins;
    present := NewArray(n, bool,, allocator = temp);
    first: Value_Id = NONE;
    while cur != NONE {
        idx := op(cur, 2);
        if !is_constant_int(idx) || op(cur, 1) != splat_val return NONE;
        nx := op(cur, 0);
        next_ie := ifx is_inst(nx) && inst_op(nx) == .INSERTELEMENT then nx else NONE;
        if cur != ins && (!has_one_use(cur) && (next_ie != NONE || !is_null_value(idx))) return NONE;
        iv := const_zext(idx);
        if iv < cast(u64) n present[iv] = true;   // SmallBitVector index (in range: InstSimplify folded the others)
        first = cur;
        cur = next_ie;
    }
    if first == ins return NONE;
    if !pm_poison(op(first, 0)) for present if !it return NONE;
    poison_vec := const_poison(vt);
    zero := const_int(ir.t_i64, 0);
    if !is_null_value(op(first, 2)) {
        ni := create_insert_element(poison_vec, splat_val, zero);
        ic_link_before(ni, ins);
        first = ni;
    }
    m := NewArray(n, s32,, allocator = temp);
    for i: 0..n-1 if !present[i] m[i] = -1;
    return create_shuffle_s32(first, NONE, m);
}

// foldInsEltIntoSplat
fold_ins_elt_into_splat :: (ins: Value_Id) -> Value_Id {
    shuf := op(ins, 0);
    if !is_inst(shuf) || inst_op(shuf) != .SHUFFLEVECTOR || !sv_is_zero_elt_splat_i(shuf) return NONE;
    if type_kind(vtype(shuf)) == .SVECTOR return NONE;
    okc, idxc := pm_constant_int_u64(op(ins, 2));
    if !okc || !is_constant_int(op(ins, 2)) return NONE;
    x := op(ins, 1);
    op0 := op(shuf, 0);
    if !is_inst(op0) || inst_op(op0) != .INSERTELEMENT || !pm_undef(op(op0, 0)) || op(op0, 1) != x || !pm_zero_int(op(op0, 2)) return NONE;
    n := cast(s64) vec_count(vtype(shuf));
    nm := NewArray(n, s32,, allocator = temp);
    for i: 0..n-1 nm[i] = ifx cast(u64) i == idxc then cast(s32) 0 else sv_mask_value(shuf, cast(u64) i);
    return create_shuffle_s32(op0, NONE, nm);
}

// foldInsEltIntoIdentityShuffle
fold_ins_elt_into_identity_shuffle :: (ins: Value_Id) -> Value_Id {
    shuf := op(ins, 0);
    if !is_inst(shuf) || inst_op(shuf) != .SHUFFLEVECTOR || !pm_poison(op(shuf, 1)) ||
       !(sv_is_identity_with_extract(shuf) || sv_is_identity_with_padding(shuf)) return NONE;
    if type_kind(vtype(shuf)) == .SVECTOR return NONE;
    okc, idxc := pm_constant_int_u64(op(ins, 2));
    if !okc || !is_constant_int(op(ins, 2)) return NONE;
    scalar := op(ins, 1);
    x := op(shuf, 0);
    if !is_inst(scalar) || inst_op(scalar) != .EXTRACTELEMENT || op(scalar, 0) != x || !pm_specific_int(op(scalar, 1), idxc) return NONE;
    n := cast(s64) vec_count(vtype(shuf));
    old := shuf_mask(shuf);
    nm := NewArray(n, s32,, allocator = temp);
    for i: 0..n-1 {
        if cast(u64) i != idxc nm[i] = old[i];
        else if old[i] == cast(s32) idxc return NONE;
        else nm[i] = cast(s32) idxc;
    }
    return create_shuffle_s32(x, op(shuf, 1), nm);
}

// hoistInsEltConst
hoist_ins_elt_const :: (ins2: Value_Id) -> Value_Id {
    ins1 := op(ins2, 0);
    if !is_inst(ins1) || inst_op(ins1) != .INSERTELEMENT || !has_one_use(ins1) return NONE;
    x := op(ins1, 0); y := op(ins1, 1);
    idx1 := op(ins1, 2); sc := op(ins2, 1); idx2 := op(ins2, 2);
    if !is_const(y) && is_constant_int(idx1) && is_const(sc) && is_constant_int(idx2) && idx1 != idx2 {
        ni := icb_insert_element(x, sc, idx2);
        return create_insert_element(ni, y, idx1);
    }
    return NONE;
}

// foldConstantInsEltIntoShuffle
fold_constant_ins_elt_into_shuffle :: (ins: Value_Id) -> Value_Id {
    i0 := op(ins, 0);
    if !is_inst(i0) || !has_one_use(i0) return NONE;
    if inst_op(i0) == .SHUFFLEVECTOR {
        shuf := i0;
        cvec := op(shuf, 1); sc := op(ins, 1);
        okc, iidx := pm_constant_int_u64(op(ins, 2));
        if !is_const(cvec) || !is_const(sc) || !okc || !is_constant_int(op(ins, 2)) return NONE;
        if !is_shuffle_equivalent_to_select(shuf) return NONE;
        m := shuf_mask(shuf);
        n := m.count;
        elts := NewArray(n, Value_Id,, allocator = temp);
        nm := NewArray(n, s32,, allocator = temp);
        for i: 0..n-1 {
            if cast(u64) i == iidx { elts[i] = sc; nm[i] = cast(s32)(iidx + cast(u64) n); }
            else { elts[i] = cf_elt(cvec, cast(u64) i); nm[i] = m[i]; }
            if elts[i] == NONE return NONE;
        }
        return create_shuffle_s32(op(shuf, 0), const_vector_of(elts), nm);
    } else if inst_op(i0) == .INSERTELEMENT {
        iei := i0;
        if type_kind(vtype(ins)) == .SVECTOR return NONE;
        n := cast(s64) vec_count(vtype(ins));
        ok0, a := pm_constant_int_u64(op(ins, 2));
        ok1, b := pm_constant_int_u64(op(iei, 2));
        if !ok0 || !is_constant_int(op(ins, 2)) || !is_const(op(ins, 1)) || !ok1 || !is_constant_int(op(iei, 2)) || !is_const(op(iei, 1)) return NONE;
        idxs: [2] u64; idxs[0] = a; idxs[1] = b;
        vals: [2] Value_Id; vals[0] = op(ins, 1); vals[1] = op(iei, 1);
        values := NewArray(n, Value_Id,, allocator = temp);
        for * values it.* = NONE;
        m := NewArray(n, s32,, allocator = temp);
        for k: 0..1 {
            ii := cast(s64) idxs[k];
            if values[ii] == NONE { values[ii] = vals[k]; m[ii] = cast(s32)(n + ii); }
        }
        for i: 0..n-1 if values[i] == NONE { values[i] = const_poison(type_elem(vtype(ins))); m[i] = cast(s32) i; }
        return create_shuffle_s32(op(iei, 0), const_vector_of(values), m);
    }
    return NONE;
}
// ConstantVector::get
const_vector_of :: (elts: [] Value_Id) -> Value_Id {
    return cfo_constant(const_aggregate(.C_VECTOR, type_vector(cast(u64) elts.count, vtype(elts[0]), false), elts));
}

// narrowInsElt
narrow_ins_elt :: (ins: Value_Id) -> Value_Id {
    vec := op(ins, 0);
    if !has_one_use(vec) return NONE;
    scalar := op(ins, 1);
    co: Opcode;
    okv, x := pm_cast(vec, .FPEXT); oks, y := pm_cast(scalar, .FPEXT);
    if okv && oks co = .FPEXT;
    else {
        okv, x = pm_cast(vec, .SEXT); oks, y = pm_cast(scalar, .SEXT);
        if okv && oks co = .SEXT;
        else {
            okv, x = pm_cast(vec, .ZEXT); oks, y = pm_cast(scalar, .ZEXT);
            if okv && oks co = .ZEXT;
            else return NONE;
        }
    }
    if scalar_type(vtype(x)) != vtype(y) return NONE;
    ni := icb_insert_element(x, y, op(ins, 2));
    return create_cast(co, ni, vtype(ins));
}

// foldTruncInsEltPair
fold_trunc_ins_elt_pair :: (ins: Value_Id, big: bool) -> Value_Id {
    vec_op := op(ins, 0); scalar_op := op(ins, 1); index_op := op(ins, 2);
    vt := vtype(ins);
    if type_kind(vt) != .VECTOR || (vec_count(vt) & 1) != 0 return NONE;
    ok1, index1 := pm_constant_int_u64(index_op);
    if !ok1 || !is_constant_int(index_op) return NONE;
    if !is_inst(vec_op) || inst_op(vec_op) != .INSERTELEMENT || !is_constant_int(op(vec_op, 2)) return NONE;
    base := op(vec_op, 0); scalar0 := op(vec_op, 1); index0 := const_zext(op(vec_op, 2));
    if !pm_undef(base) return NONE;
    if index0 + 1 != index1 || (index0 & 1) != 0 return NONE;
    x: Value_Id; sh: u64;
    hi_lo :: (lo: Value_Id, hi: Value_Id) -> (bool, Value_Id, u64) {
        okt, x := pmi_cast(lo, .TRUNC);
        if !okt return false, NONE, 0;
        okh, s := pmi_cast(hi, .TRUNC);
        if !okh || !is_inst(s) || inst_op(s) != .LSHR || op(s, 0) != x return false, NONE, 0;
        okc, amt := pm_constant_int_u64(op(s, 1));
        if !okc || !is_constant_int(op(s, 1)) return false, NONE, 0;
        return true, x, amt;
    }
    ok: bool;
    if big ok, x, sh = hi_lo(scalar_op, scalar0);
    else ok, x, sh = hi_lo(scalar0, scalar_op);
    if !ok return NONE;
    src_ty := vtype(x);
    sw := scalar_bits(x);
    ew := type_bits(scalar_type(vt));
    if sw != ew * 2 || sh != cast(u64) ew return NONE;
    cast_ty := type_vector(vec_count(vt) / 2, src_ty, false);
    cb := icb_cast(.BITCAST, base, cast_ty);
    new_index := ifx big then index1 / 2 else index0 / 2;
    ni := icb_insert_element(cb, x, const_int(ir.t_i64, new_index));
    return create_cast(.BITCAST, ni, vt);
}

// visitInsertElementInst
ic_visit_insert_element :: (ie: Value_Id) -> Value_Id {
    vec_op := op(ie, 0); scalar_op := op(ie, 1); idx_op := op(ie, 2);
    v := simplify_insert_element_inst(vec_op, scalar_op, idx_op, ic_q(ie));
    if v != NONE return ic_replace_inst_uses_with(ie, v);
    if is_constant_int(idx_op) {
        ni := get_preferred_vector_index(idx_op);
        if ni != NONE return ic_replace_operand(ie, 2, ni);
        if is_inst(vec_op) && inst_op(vec_op) == .INSERTELEMENT && has_one_use(vec_op) && is_constant_int(op(vec_op, 2)) {
            base := op(vec_op, 0); other := op(vec_op, 1); oiv := const_zext(op(vec_op, 2));
            if !is_const(other) && oiv > const_zext(idx_op) {
                nins := icb_insert_element(base, scalar_op, idx_op);
                return create_insert_element(nins, other, const_int(ir.t_i64, oiv));
            }
        }
    }
    if pm_undef(vec_op) && is_inst(scalar_op) && inst_op(scalar_op) == .BITCAST && has_one_use(scalar_op) {
        ss := op(scalar_op, 0);
        if is_int_type(vtype(ss)) || is_fp_type(vtype(ss)) {
            vt := type_vector(vec_count(vtype(ie)), vtype(ss), type_kind(vtype(ie)) == .SVECTOR);
            nu := ifx vkind(vec_op) == .C_POISON then const_poison(vt) else const_undef(vt);
            ni := icb_insert_element(nu, ss, idx_op);
            return create_cast(.BITCAST, ni, vtype(ie));
        }
    }
    {
        okv, vec_src := pm_cast(vec_op, .BITCAST);
        oks, scalar_src := pm_cast(scalar_op, .BITCAST);
        if okv && oks && (has_one_use(vec_op) || has_one_use(scalar_op)) && is_vector_type(vtype(vec_src)) &&
           !is_vector_type(vtype(scalar_src)) && type_elem(vtype(vec_src)) == vtype(scalar_src) {
            ni := icb_insert_element(vec_src, scalar_src, idx_op);
            return create_cast(.BITCAST, ni, vtype(ie));
        }
    }
    if type_kind(vtype(ie)) == .VECTOR && is_constant_int(idx_op) && is_inst(scalar_op) && inst_op(scalar_op) == .EXTRACTELEMENT &&
       is_constant_int(op(scalar_op, 1)) && type_kind(vtype(op(scalar_op, 0))) == .VECTOR &&
       const_zext(op(scalar_op, 1)) < vec_count(vtype(op(scalar_op, 0))) {
        root_candidate := !has_one_use(ie) || inst_op(first_user(ie)) != .INSERTELEMENT;
        if root_candidate {
            rerun := true;
            while rerun {
                rerun = false;
                mask: [..] s32; mask.allocator = temp;
                l, r := collect_shuffle_elements(ie, *mask, NONE, *rerun);
                if l != ie && r != ie {
                    rr := r;
                    if rr == NONE rr = const_poison(vtype(l));
                    return create_shuffle_s32(l, rr, mask);
                }
            }
        }
    }
    if type_kind(vtype(vec_op)) == .VECTOR {
        vw := cast(u32) vec_count(vtype(vec_op));
        poison := ap_zero(vw);
        r := ic_simplify_demanded_vector_elts(ie, ap_all_ones(vw), *poison);
        if r != NONE {
            if r != ie return ic_replace_inst_uses_with(ie, r);
            return ie;
        }
    }
    r := fold_constant_ins_elt_into_shuffle(ie); if r != NONE return r;
    r = hoist_ins_elt_const(ie); if r != NONE return r;
    r = fold_ins_sequence_into_splat(ie); if r != NONE return r;
    r = fold_ins_elt_into_splat(ie); if r != NONE return r;
    r = fold_ins_elt_into_identity_shuffle(ie); if r != NONE return r;
    r = narrow_ins_elt(ie); if r != NONE return r;
    r = fold_trunc_ins_elt_pair(ie, dl.big_endian); if r != NONE return r;
    return NONE;
}

// ---------------------------------------------------------------- shufflevector

// canEvaluateShuffled
can_evaluate_shuffled :: (v: Value_Id, mask: [] s32, depth: u32 = 5) -> bool {
    if is_const(v) return true;
    if !is_inst(v) return false;
    if !has_one_use(v) return false;
    if depth == 0 return false;
    o := inst_op(v);
    if o == .UDIV || o == .SDIV || o == .UREM || o == .SREM { for mask if it == -1 return false; }
    if is_binary_op(o) || o == .ICMP || o == .FCMP || o == .TRUNC || o == .ZEXT || o == .SEXT || o == .FPTOUI ||
       o == .FPTOSI || o == .UITOFP || o == .SITOFP || o == .FPTRUNC || o == .FPEXT || o == .GEP {
        it_ := vtype(v);
        if is_vector_type(it_) && cast(u64) mask.count > vec_count(it_) return false;
        for k: 0..cast(s64) nops(v) - 1 if !can_evaluate_shuffled(op(v, cast(u32) k), mask, depth - 1) return false;
        return true;
    }
    if o == .INSERTELEMENT {
        ci := op(v, 2);
        if !is_constant_int(ci) return false;
        en := cast(s64) ap_limited(const_ap(ci));
        seen := false;
        for mask if it == en { if seen return false; seen = true; }
        return can_evaluate_shuffled(op(v, 0), mask, depth - 1);
    }
    return false;
}

// buildNew
build_new :: (i: Value_Id, new_ops: [] Value_Id) -> Value_Id {
    icb_set_insert_point(i);
    o := inst_op(i);
    if is_binary_op(o) {
        nv := icb_binop(o, new_ops[0], new_ops[1]);
        if is_inst(nv) {
            if is_overflowing_binop(i) { set_nuw(nv, has_nuw(i)); set_nsw(nv, has_nsw(i)); }
            if is_possibly_exact_op(i) set_exact(nv, (inst(i).flags & F_EXACT) != 0);
            if is_fp_math_op_value(i) set_fmf(nv, get_fmf(i));
        }
        return nv;
    }
    if o == .ICMP || o == .FCMP return icb_cmp(inst(i).pred, new_ops[0], new_ops[1]);
    if is_cast_op(o) {
        nt := vtype(new_ops[0]);
        dt := type_vector(vec_count(nt), scalar_type(vtype(i)), type_kind(nt) == .SVECTOR);
        return icb_cast(o, new_ops[0], dt);
    }
    if o == .GEP return icb_gep(opr_gep_source_type(i), new_ops[0], aview(new_ops, 1, new_ops.count - 1), "", gep_nw_bits(i));
    fatal("internal: failed to rebuild vector instructions");
    return NONE;
}

// evaluateInDifferentElementOrder
evaluate_in_different_element_order :: (v: Value_Id, mask: [] s32) -> Value_Id {
    et := scalar_type(vtype(v));
    nt := type_vector(cast(u64) mask.count, et, false);
    if vkind(v) == .C_POISON return const_poison(nt);
    if pm_undef(v) return const_undef(nt);
    if vkind(v) == .C_ZERO return const_null_value(nt);
    if is_const(v) return ce_shuffle_vector(v, const_poison(vtype(v)), mask_to_u32(mask));
    i := v;
    o := inst_op(i);
    if is_binary_op(o) || o == .ICMP || o == .FCMP || (is_cast_op(o) && o != .BITCAST && o != .PTRTOINT && o != .INTTOPTR && o != .ADDRSPACECAST && o != .PTRTOADDR) || o == .SELECT || o == .GEP {
        new_ops: [..] Value_Id; new_ops.allocator = temp;
        needs := cast(u64) mask.count != vec_count(vtype(i));
        for k: 0..cast(s64) nops(i) - 1 {
            x := op(i, cast(u32) k);
            nv := ifx is_vector_type(vtype(x)) then evaluate_in_different_element_order(x, mask) else x;
            array_add(*new_ops, nv);
            needs |= nv != x;
        }
        if needs return build_new(i, new_ops);
        return i;
    }
    if o == .INSERTELEMENT {
        element := cast(s32) ap_limited(const_ap(op(i, 2)));
        found := false;
        index := 0;
        while index != mask.count { if mask[index] == element { found = true; break; } index += 1; }
        if !found return evaluate_in_different_element_order(op(i, 0), mask);
        nv := evaluate_in_different_element_order(op(i, 0), mask);
        icb_set_insert_point(i);
        return icb_insert_element(nv, op(i, 1), const_int(ir.t_i64, cast(u64) index));
    }
    fatal("internal: failed to reorder elements of vector instruction");
    return NONE;
}

// isShuffleExtractingFromLHS
is_shuffle_extracting_from_lhs :: (svi: Value_Id, mask: [] s32) -> bool {
    lhs_elems := cast(u32) vec_count(vtype(op(svi, 0)));
    me := cast(u32) mask.count;
    beg := cast,no_check(u32) mask[0]; end := cast,no_check(u32) mask[mask.count - 1];
    if beg > end || end >= lhs_elems || end - beg != me - 1 return false;
    for mask if cast,no_check(u32) it != beg + cast(u32) it_index return false;
    return true;
}

// getAlternateBinop: (opcode or NONE_OP, op0, op1)
get_alternate_binop :: (bo: Value_Id) -> (Opcode, Value_Id, Value_Id) {
    b0 := op(bo, 0); b1 := op(bo, 1);
    ty := vtype(bo);
    o := inst_op(bo);
    if o == .SHL {
        if pm_imm_constant(b1) {
            shl_one := cfo_binary_op_operands(.SHL, const_int_signed(ty, 1), b1);
            return .MUL, b0, shl_one;
        }
    } else if o == .OR {
        if (inst(bo).flags & F_EXACT) != 0 return .ADD, b0, b1;
    } else if o == .SUB {
        if pm_zero_int(b0) return .MUL, b1, const_all_ones_of(ty);
    }
    return .NONE_OP, NONE, NONE;
}

// foldSelectShuffleOfSelectShuffle
fold_select_shuffle_of_select_shuffle :: (shuf: Value_Id) -> Value_Id {
    op0 := op(shuf, 0); op1 := op(shuf, 1);
    mask := shuf_mask(shuf);
    n := mask.count;
    is_sel_shuf :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .SHUFFLEVECTOR && sv_is_select(v); }
    if is_sel_shuf(op0) && (op(op0, 0) == op1 || op(op0, 1) == op1) {
        t := op0; op0 = op1; op1 = t;
        commute_shuffle_mask(*mask, n);
    }
    so := op1;
    if !is_sel_shuf(so) || (op(so, 0) != op0 && op(so, 1) != op0) return NONE;
    x := op(so, 0); y := op(so, 1);
    mask1 := shuf_mask(so);
    if y == op0 { t := x; x = y; y = t; commute_shuffle_mask(*mask1, n); }
    nm := NewArray(n, s32,, allocator = temp);
    for i: 0..n-1 nm[i] = ifx mask[i] < n then mask[i] else mask1[i];
    return create_shuffle_s32(x, y, nm);
}

// getSafeVectorConstantForBinop
ic_get_safe_vector_constant_for_binop :: (opc: Opcode, in_c: Value_Id, is_rhs_constant: bool) -> Value_Id {
    et := type_elem(vtype(in_c));
    safe := cf_binop_identity(opc, et, is_rhs_constant);
    if safe == NONE {
        if is_rhs_constant {
            if opc == .SREM || opc == .UREM safe = const_int(et, 1);
            else if opc == .FREM safe = cf_fp_one(et);
            else fatal("internal: only rem opcodes have no identity constant for RHS");
        } else {
            if opc == .SHL || opc == .LSHR || opc == .ASHR || opc == .SDIV || opc == .UDIV || opc == .SREM || opc == .UREM ||
               opc == .SUB || opc == .FSUB || opc == .FDIV || opc == .FREM safe = const_null_value(et);
            else fatal("internal: expected to find identity constant for opcode");
        }
    }
    n := cast(s64) vec_count(vtype(in_c));
    out := NewArray(n, Value_Id,, allocator = temp);
    for i: 0..n-1 {
        c := cf_elt(in_c, cast(u64) i);
        out[i] = ifx vkind(c) == .C_UNDEF || vkind(c) == .C_POISON then safe else c;
    }
    return cfo_constant(const_aggregate(.C_VECTOR, vtype(in_c), out));
}
// ConstantFP::get(Ty, 1.0)
cf_fp_one :: (t: Type_Id) -> Value_Id { return cfo_cast_operand(.SITOFP, const_int(ir.t_i32, 1), t); }

// foldSelectShuffleWith1Binop
fold_select_shuffle_with_1_binop :: (shuf: Value_Id, q: Simplify_Query) -> Value_Id {
    op0 := op(shuf, 0); op1 := op(shuf, 1);
    c: Value_Id;
    op0_is_binop: bool;
    if is_inst(op0) && is_binary_op(inst_op(op0)) && op(op0, 0) == op1 && is_const(op(op0, 1)) { op0_is_binop = true; c = op(op0, 1); }
    else if is_inst(op1) && is_binary_op(inst_op(op1)) && op(op1, 0) == op0 && is_const(op(op1, 1)) { op0_is_binop = false; c = op(op1, 1); }
    else return NONE;
    bo := ifx op0_is_binop then op0 else op1;
    bopc := inst_op(bo);
    idc := cf_binop_identity(bopc, vtype(shuf), true);
    if idc == NONE return NONE;
    x := ifx op0_is_binop then op1 else op0;
    is_fp := is_fp_type(type_elem(vtype(shuf)));
    if is_fp && !kfpc_is_known_never_nan(compute_known_fp_class(x, FC_NAN, q)) return NONE;
    m := shuf_mask(shuf);
    um := mask_to_u32(m);
    new_c := ifx op0_is_binop then ce_shuffle_vector(c, idc, um) else ce_shuffle_vector(idc, c, um);
    has_poison := false;
    for m if it == -1 has_poison = true;
    might := has_poison && (is_int_div_rem(bopc) || is_shift_op(bopc));
    if might new_c = ic_get_safe_vector_constant_for_binop(bopc, new_c, true);
    nb := create_binop(bopc, x, new_c);
    copy_ir_flags(nb, bo);
    if is_fp && (get_fmf(nb) & FMF_NINF) != 0 && !kfpc_is_known_never_infinity(compute_known_fp_class(x, FC_INF, q))
        set_fmf(nb, get_fmf(nb) & ~cast(u32) FMF_NINF);
    if has_poison && !might drop_poison_generating_flags(nb);
    return nb;
}

// canonicalizeInsertSplat
canonicalize_insert_splat :: (shuf: Value_Id) -> Value_Id {
    op0 := op(shuf, 0); op1 := op(shuf, 1);
    m := shuf_mask(shuf);
    if !is_inst(op0) || inst_op(op0) != .INSERTELEMENT || !has_one_use(op0) || !pm_poison(op(op0, 0)) || !is_constant_int(op(op0, 2)) return NONE;
    x := op(op0, 1); index_c := const_zext(op(op0, 2));
    zero_mask := true;
    for m if it != 0 && it != -1 zero_mask = false;
    if !pm_poison(op1) || zero_mask || index_c == 0 return NONE;
    pv := const_poison(vtype(shuf));
    ni := icb_insert_element(pv, x, const_int(ir.t_i64, 0));
    n := cast(s64) vec_count(vtype(shuf));
    nm := NewArray(n, s32,, allocator = temp);
    for i: 0..n-1 if m[i] == -1 nm[i] = -1;
    return create_shuffle_s32(ni, NONE, nm);
}

// foldSelectShuffle
ic_fold_select_shuffle :: (shuf: Value_Id) -> Value_Id {
    if !sv_is_select(shuf) return NONE;
    n := cast(s64) vec_count(vtype(shuf));
    if !pm_undef(op(shuf, 1)) && sv_mask_value(shuf, 0) >= n {
        sv_commute(shuf);
        return shuf;
    }
    r := fold_select_shuffle_of_select_shuffle(shuf); if r != NONE return r;
    r = fold_select_shuffle_with_1_binop(shuf, ic_q(shuf)); if r != NONE return r;
    b0 := op(shuf, 0); b1 := op(shuf, 1);
    if !is_inst(b0) || !is_binary_op(inst_op(b0)) || !is_inst(b1) || !is_binary_op(inst_op(b1)) return NONE;
    x, y: Value_Id; c0: Value_Id = NONE; c1: Value_Id = NONE;
    constants_are_op1: bool;
    if is_const(op(b0, 0)) && is_const(op(b1, 0)) {
        c0 = op(b0, 0); x = op(b0, 1); c1 = op(b1, 0); y = op(b1, 1);
        constants_are_op1 = false;
    } else {
        side :: (b: Value_Id) -> (bool, Value_Id, Value_Id) {
            if is_const(op(b, 1)) return true, op(b, 0), op(b, 1);
            okn, nx := pm_neg(b);
            if okn return true, nx, NONE;
            return false, NONE, NONE;
        }
        ok0, xs, cc0 := side(b0);
        ok1, yy, cc1 := side(b1);
        if !ok0 || !ok1 return NONE;
        x = xs; c0 = cc0; y = yy; c1 = cc1;
        constants_are_op1 = true;
    }
    opc0 := inst_op(b0); opc1 := inst_op(b1);
    drop_nsw := false;
    if constants_are_op1 && opc0 != opc1 {
        if opc0 == .SHL || opc1 == .SHL drop_nsw = true;
        a0, _, ac0 := get_alternate_binop(b0);
        if a0 != .NONE_OP { opc0 = a0; c0 = ac0; }
        else {
            a1, _, ac1 := get_alternate_binop(b1);
            if a1 != .NONE_OP { opc1 = a1; c1 = ac1; }
        }
    }
    if opc0 != opc1 || c0 == NONE || c1 == NONE return NONE;
    bopc := opc0;
    m := shuf_mask(shuf);
    um := mask_to_u32(m);
    new_c := ce_shuffle_vector(c0, c1, um);
    has_poison := false;
    for m if it == -1 has_poison = true;
    might := has_poison && (is_int_div_rem(bopc) || is_shift_op(bopc));
    if might new_c = ic_get_safe_vector_constant_for_binop(bopc, new_c, constants_are_op1);
    v: Value_Id;
    if x == y v = x;
    else {
        if !has_one_use(b0) && !has_one_use(b1) return NONE;
        if might && !constants_are_op1 return NONE;
        v = icb_shuffle(x, y, um);
    }
    nb := ifx constants_are_op1 then icb_binop(bopc, v, new_c) else icb_binop(bopc, new_c, v);
    if is_inst(nb) {
        copy_ir_flags(nb, b0);
        and_ir_flags(nb, b1);
        if drop_nsw set_nsw(nb, false);
        if has_poison && !might drop_poison_generating_flags(nb);
    }
    return ic_replace_inst_uses_with(shuf, nb);
}
// ShuffleVectorInst::commute
sv_commute :: (sv: Value_Id) {
    n := cast(s64) vec_count(vtype(op(sv, 0)));
    m := shuf_mask(sv);
    for * m {
        if it.* == -1 continue;
        it.* = ifx it.* < n then it.* + cast(s32) n else it.* - cast(s32) n;
    }
    use_swap(op_use(sv, 0), op_use(sv, 1));
    r := inst(sv);
    r.idx = cast(u32) ir.u32_pool.count;
    for m array_add(*ir.u32_pool, ifx it < 0 then 0xFFFF_FFFF else cast(u32) it);
}

// m_ZeroMask
is_zero_mask :: (m: [] s32) -> bool { for m if it != 0 && it != -1 return false; return true; }

// foldTruncShuffle
fold_trunc_shuffle :: (shuf: Value_Id, big: bool) -> Value_Id {
    dt := vtype(shuf);
    okb, x := pm_cast(op(shuf, 0), .BITCAST);
    if !okb || !pm_poison(op(shuf, 1)) || !is_int_type(scalar_type(dt)) return NONE;
    st := vtype(x);
    if !is_vector_type(st) || !is_int_type(scalar_type(st)) || vec_count(st) != vec_count(dt) ||
       type_bits(scalar_type(st)) % type_bits(scalar_type(dt)) != 0 return NONE;
    ratio := cast(u64)(type_bits(scalar_type(st)) / type_bits(scalar_type(dt)));
    m := shuf_mask(shuf);
    for m {
        if it == -1 continue;
        lsb := ifx big then (cast(u64) it_index + 1) * ratio - 1 else cast(u64) it_index * ratio;
        if cast(u64) it != lsb return NONE;
    }
    return create_cast(.TRUNC, x, dt);
}

// narrowVectorSelect
narrow_vector_select :: (shuf: Value_Id) -> Value_Id {
    if !pm_poison(op(shuf, 1)) || !sv_is_identity_with_extract(shuf) return NONE;
    s0 := op(shuf, 0);
    if !is_inst(s0) || inst_op(s0) != .SELECT || !has_one_use(s0) return NONE;
    cond := op(s0, 0); x := op(s0, 1); y := op(s0, 2);
    n := vec_count(vtype(shuf));
    if !is_inst(cond) || inst_op(cond) != .SHUFFLEVECTOR || !has_one_use(cond) || !pm_poison(op(cond, 1)) return NONE;
    nc := op(cond, 0);
    if vec_count(vtype(nc)) != n || !sv_is_identity_with_padding(cond) return NONE;
    m := shuf_mask(shuf);
    nx := icb_shuffle_s32(x, NONE, m);
    ny := icb_shuffle_s32(y, NONE, m);
    return create_select(nc, nx, ny);
}

// foldShuffleOfUnaryOps
fold_shuffle_of_unary_ops :: (shuf: Value_Id) -> Value_Id {
    s0 := op(shuf, 0);
    unary :: (s: Value_Id) -> (bool, Value_Id, bool) {
        if !is_inst(s) return false, NONE, false;
        if inst_op(s) == .FNEG return true, op(s, 0), true;
        if call_iid(s) == IID_FABS return true, call_arg(s, 0), false;
        return false, NONE, false;
    }
    ok0, x, is_fneg := unary(s0);
    if !ok0 return NONE;
    s1 := op(shuf, 1);
    ok1, y, is_fneg1 := unary(s1);
    if !ok1 || inst_op(s0) != inst_op(s1) || (!has_one_use(s0) && !has_one_use(s1)) return NONE;
    ns := icb_shuffle_s32(x, y, shuf_mask(shuf));
    nf: Value_Id;
    if is_fneg { nf = new_inst(.FNEG, vtype(ns), 1); set_op(nf, 0, ns); }
    else nf = create_intrinsic_call(IID_FABS, .[vtype(shuf)], .[ns]);
    copy_ir_flags(nf, s0);
    and_ir_flags(nf, s1);
    return nf;
}

// foldCastShuffle
fold_cast_shuffle :: (shuf: Value_Id) -> Value_Id {
    c0 := op(shuf, 0);
    if !is_inst(c0) || !is_cast_op(inst_op(c0)) return NONE;
    co := inst_op(c0);
    if co != .SEXT && co != .ZEXT && co != .FPTOSI && co != .FPTOUI && co != .SITOFP && co != .UITOFP return NONE;
    cast_src_ty := vtype(op(c0, 0));
    shuf_ty := vtype(shuf);
    shuf_op_ty := vtype(c0);
    if vec_count(shuf_ty) > vec_count(shuf_op_ty) return NONE;
    if vkind(op(shuf, 1)) == .C_POISON && has_one_use(c0) && sv_is_identity_with_extract(shuf) {
        ni := icb_shuffle_s32(op(c0, 0), const_poison(cast_src_ty), shuf_mask(shuf));
        return create_cast(co, ni, shuf_ty);
    }
    c1 := op(shuf, 1);
    if !is_inst(c1) || !is_cast_op(inst_op(c1)) || inst_op(c1) != co || vtype(op(c1, 0)) != cast_src_ty return NONE;
    a, _ := prim_size_bits(cast_src_ty); b, _ := prim_size_bits(shuf_op_ty);
    if a > b return NONE;
    if !has_one_use(c0) && !has_one_use(c1) return NONE;
    ns := icb_shuffle_s32(op(c0, 0), op(c1, 0), shuf_mask(shuf));
    return create_cast(co, ns, shuf_ty);
}

// foldIdentityExtractShuffle
fold_identity_extract_shuffle :: (shuf: Value_Id) -> Value_Id {
    op0 := op(shuf, 0); op1 := op(shuf, 1);
    if !sv_is_identity_with_extract(shuf) || !pm_poison(op1) return NONE;
    okb, ie := pm_cast(op0, .BITCAST);
    if okb && is_inst(ie) && inst_op(ie) == .INSERTELEMENT && pm_zero(op(ie, 2)) {
        x := op(ie, 1);
        a, _ := prim_size_bits(vtype(x)); b, _ := prim_size_bits(vtype(shuf));
        if a == b return create_cast(.BITCAST, x, vtype(shuf));
    }
    if !is_inst(op0) || inst_op(op0) != .SHUFFLEVECTOR return NONE;
    x := op(op0, 0); y := op(op0, 1);
    mask := shuf_mask(op0);
    if !has_one_use(op0) return NONE;
    n := cast(s64) vec_count(vtype(shuf));
    nm := NewArray(n, s32,, allocator = temp);
    for i: 0..n-1 {
        e := sv_mask_value(shuf, cast(u64) i);
        nm[i] = ifx e == -1 then e else mask[i];
    }
    return create_shuffle_s32(x, y, nm);
}

// foldShuffleWithInsert
fold_shuffle_with_insert :: (shuf: Value_Id) -> Value_Id {
    v0 := op(shuf, 0); v1 := op(shuf, 1);
    mask := shuf_mask(shuf);
    n := mask.count;
    inp := cast(s64) vec_count(vtype(v0));
    contains :: (m: [] s32, x: s64) -> bool { for m if it == x return true; return false; }
    if is_inst(v0) && inst_op(v0) == .INSERTELEMENT && is_constant_int(op(v0, 2)) {
        if !contains(mask, cast(s64) const_zext(op(v0, 2))) return ic_replace_operand(shuf, 0, op(v0, 0));
    }
    if is_inst(v1) && inst_op(v1) == .INSERTELEMENT && is_constant_int(op(v1, 2)) {
        idx := cast(s64) const_zext(op(v1, 2)) + inp;
        if !contains(mask, idx) return ic_replace_operand(shuf, 1, op(v1, 0));
    }
    if n != inp return NONE;
    into_op1 :: (v0: Value_Id, mask: [] s32, n: s64) -> (bool, Value_Id, Value_Id) {
        if !is_inst(v0) || inst_op(v0) != .INSERTELEMENT || !is_constant_int(op(v0, 2)) return false, NONE, NONE;
        scalar := op(v0, 1); index_c := op(v0, 2);
        new_idx := -1;
        for i: 0..n-1 {
            if mask[i] == -1 continue;
            if mask[i] == n + i continue;
            if new_idx != -1 || cast(s64) mask[i] != ap_sext_value(const_ap(index_c)) return false, NONE, NONE;
            new_idx = i;
        }
        return true, scalar, const_int(vtype(index_c), cast(u64) new_idx);
    }
    ok, scalar, ic := into_op1(v0, mask, n);
    if ok return create_insert_element(v1, scalar, ic);
    t := v0; v0 = v1; v1 = t;
    commute_shuffle_mask(*mask, n);
    ok, scalar, ic = into_op1(v0, mask, n);
    if ok return create_insert_element(v1, scalar, ic);
    return NONE;
}

// foldIdentityPaddedShuffles
fold_identity_padded_shuffles :: (shuf: Value_Id) -> Value_Id {
    s0 := op(shuf, 0); s1 := op(shuf, 1);
    if !is_inst(s0) || inst_op(s0) != .SHUFFLEVECTOR || !sv_is_identity_with_padding(s0) ||
       !is_inst(s1) || inst_op(s1) != .SHUFFLEVECTOR || !sv_is_identity_with_padding(s1) return NONE;
    x := op(s0, 0); y := op(s1, 0);
    p2 :: (n: u64) -> bool { return n != 0 && (n & (n - 1)) == 0; }
    if vtype(x) != vtype(y) || !p2(vec_count(vtype(shuf))) || !p2(vec_count(vtype(s0))) || !p2(vec_count(vtype(x))) ||
       pm_undef(x) || pm_undef(y) return NONE;
    narrow := cast(s64) vec_count(vtype(x));
    wide := cast(s64) vec_count(vtype(s0));
    m := shuf_mask(shuf);
    nm := NewArray(m.count, s32,, allocator = temp);
    for * nm it.* = -1;
    for i: 0..m.count-1 {
        if m[i] == -1 continue;
        if m[i] < wide { if sv_mask_value(s0, cast(u64) m[i]) == -1 continue; }
        else { if sv_mask_value(s1, cast(u64)(m[i] - wide)) == -1 continue; }
        if m[i] < wide nm[i] = m[i];
        else nm[i] = cast(s32)(m[i] - (wide - narrow));
    }
    return create_shuffle_s32(x, y, nm);
}

// simplifyBinOpSplats
ic_simplify_binop_splats :: (svi: Value_Id) -> Value_Id {
    if !pm_poison(op(svi, 1)) || !is_zero_mask(shuf_mask(svi)) || !has_one_use(op(svi, 0)) return NONE;
    op0 := op(svi, 0);
    if !is_inst(op0) || !is_binary_op(inst_op(op0)) return NONE;
    is_zero_splat :: (v: Value_Id) -> (bool, Value_Id) {
        if !is_inst(v) || inst_op(v) != .SHUFFLEVECTOR || !pm_poison(op(v, 1)) || !is_zero_mask(shuf_mask(v)) return false, NONE;
        return true, op(v, 0);
    }
    x, y: Value_Id;
    ok, sx := is_zero_splat(op(op0, 0));
    if ok { x = sx; y = op(op0, 1); }
    else {
        ok2, sy := is_zero_splat(op(op0, 1));
        if !ok2 return NONE;
        x = op(op0, 0); y = sy;
    }
    if vtype(x) != vtype(y) return NONE;
    if !is_safe_to_speculate_binop_variable_replaced(op0) return NONE;
    nb := icb_binop(inst_op(op0), x, y);
    if is_inst(nb) copy_ir_flags(nb, op0);
    return create_shuffle_s32(nb, NONE, shuf_mask(svi));
}

// scaleShuffleMaskElts (VectorUtils.cpp): (ok, scaled)
scale_shuffle_mask_elts :: (num_dst: s64, mask: [] s32) -> (bool, [..] s32) {
    out: [..] s32; out.allocator = temp;
    num_src := mask.count;
    if num_src == num_dst { for mask array_add(*out, it); return true, out; }
    if num_src > num_dst {
        scale := num_src / num_dst;
        if num_src % scale != 0 return false, out;
        k := 0;
        while k < num_src {
            front := mask[k];
            if front < 0 {
                for i: 1..scale-1 if mask[k + i] != front return false, out;
                array_add(*out, front);
            } else {
                if front % scale != 0 return false, out;
                for i: 1..scale-1 if mask[k + i] != front + i return false, out;
                array_add(*out, cast(s32)(front / scale));
            }
            k += scale;
        }
        return true, out;
    }
    scale := num_dst / num_src;
    for mask for s: 0..scale-1 array_add(*out, ifx it < 0 then it else cast(s32)(scale * it + s));
    return true, out;
}
// createUnaryMask
create_unary_mask :: (mask: [] s32, n: s64) -> [] s32 {
    out := NewArray(mask.count, s32,, allocator = temp);
    for mask out[it_index] = ifx it >= n then cast(s32)(it - n) else it;
    return out;
}
// VectorType::isValidElementType
is_valid_vector_element_type :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .INT || is_fp_type(t) || k == .PTR || k == .BYTE return true;
    if k == .TARGET_EXT fatal("instcombine: TargetExtType::CanBeVectorElement is not supported yet");
    return false;
}
masks_eq :: (a: [] s32, b: [] s32) -> bool { if a.count != b.count return false; for a if it != b[it_index] return false; return true; }

// visitShuffleVectorInst
ic_visit_shuffle_vector :: (svi: Value_Id) -> Value_Id {
    lhs := op(svi, 0); rhs := op(svi, 1);
    q := ic_q(svi);
    v := simplify_shuffle_vector_inst(lhs, rhs, shuffle_mask(svi), vtype(svi), q);
    if v != NONE return ic_replace_inst_uses_with(svi, v);
    r := ic_simplify_binop_splats(svi); if r != NONE return r;
    if is_zero_mask(shuf_mask(svi)) && vkind(rhs) != .C_POISON return ic_replace_operand(svi, 1, const_poison(vtype(rhs)));
    if type_kind(vtype(lhs)) == .SVECTOR return NONE;
    vwidth := cast(s64) vec_count(vtype(svi));
    lhs_width := cast(s64) vec_count(vtype(lhs));
    {
        okx, x := pm_cast(lhs, .BITCAST); oky, y := pm_cast(rhs, .BITCAST);
        if okx && oky && is_vector_type(vtype(x)) && vtype(x) == vtype(y) && type_bits(scalar_type(vtype(x))) == type_bits(scalar_type(vtype(svi))) &&
           (has_one_use(lhs) || has_one_use(rhs)) {
            nv := icb_shuffle_s32(x, y, shuf_mask(svi), tprint("%.uncasted", vname(svi)));
            return create_cast(.BITCAST, nv, vtype(svi));
        }
    }
    mask := shuf_mask(svi);
    {
        okx, x := pm_cast(lhs, .BITCAST);
        if okx && pm_undef(rhs) && is_vector_type(vtype(x)) && vwidth == lhs_width {
            xt := vtype(x);
            ok, scaled := scale_shuffle_mask_elts(cast(s64) vec_count(xt), mask);
            if ok {
                sv := simplify_shuffle_vector_inst(x, const_undef(xt), mask_to_u32(scaled), xt, q);
                if sv != NONE return create_cast(.BITCAST, sv, vtype(svi));
            }
        }
    }
    if lhs == rhs return create_shuffle_s32(lhs, NONE, create_unary_mask(mask, lhs_width));
    if pm_undef(lhs) { sv_commute(svi); return svi; }
    r = canonicalize_insert_splat(svi); if r != NONE return r;
    r = ic_fold_select_shuffle(svi); if r != NONE return r;
    r = fold_trunc_shuffle(svi, dl.big_endian); if r != NONE return r;
    r = narrow_vector_select(svi); if r != NONE return r;
    r = fold_shuffle_of_unary_ops(svi); if r != NONE return r;
    r = fold_cast_shuffle(svi); if r != NONE return r;
    {
        poison := ap_zero(cast(u32) vwidth);
        dv := ic_simplify_demanded_vector_elts(svi, ap_all_ones(cast(u32) vwidth), *poison);
        if dv != NONE {
            if dv != svi return ic_replace_inst_uses_with(svi, dv);
            return svi;
        }
    }
    r = fold_identity_extract_shuffle(svi); if r != NONE return r;
    r = fold_shuffle_with_insert(svi); if r != NONE return r;
    r = fold_identity_padded_shuffles(svi); if r != NONE return r;
    if is_const(rhs) {
        if is_inst(lhs) && inst_op(lhs) == .SELECT {
            if is_int_type(vtype(op(lhs, 0))) && (vkind(rhs) == .C_POISON || is_guaranteed_not_to_be_poison(op(lhs, 0))) {
                r = ic_fold_op_into_select(svi, lhs); if r != NONE return r;
            }
        }
        if is_phi(lhs) { r = ic_fold_op_into_phi(svi, lhs, true); if r != NONE return r; }
    }
    mask = shuf_mask(svi);
    if pm_poison(rhs) && can_evaluate_shuffled(lhs, mask) {
        ev := evaluate_in_different_element_order(lhs, mask);
        return ic_replace_inst_uses_with(svi, ev);
    }
    made_change := false;
    if is_shuffle_extracting_from_lhs(svi, mask) {
        vv := lhs;
        mask_elems := mask.count;
        src_ty := vtype(vv);
        vec_bw := dl_type_size_bits(src_ty);
        src_elem_bw := dl_type_size_bits(type_elem(src_ty));
        src_num := cast(s64) vec_count(src_ty);
        bcs: [..] Value_Id; bcs.allocator = temp;
        u := ir.v_first_use[svi];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(us) || inst_op(us) != .BITCAST continue;
            if !has_uses(us) continue;
            if has_one_use(us) {
                bc2 := first_user(us);
                if is_inst(bc2) && inst_op(bc2) == .BITCAST && ic_is_eliminable_cast_pair(us, bc2) != .NONE_OP continue;
            }
            array_add(*bcs, us);
        }
        nbc_keys: [..] Type_Id; nbc_keys.allocator = temp;
        nbc_vals: [..] Value_Id; nbc_vals.allocator = temp;
        for bc: bcs {
            beg := cast(u64) mask[0];
            tgt := vtype(bc);
            tgt_bw := dl_type_size_bits(tgt);
            if tgt_bw == 0 continue;
            tgt_num := vec_bw / tgt_bw;
            equal := vec_bw == tgt_num * tgt_bw;
            aligned := ((src_elem_bw * beg) % tgt_bw) == 0;
            if !equal continue;
            if !is_valid_vector_element_type(tgt) continue;
            cast_src_ty := type_vector(tgt_num, tgt, false);
            if !aligned {
                sm := NewArray(src_num, s32,, allocator = temp);
                for * sm it.* = -1;
                idx := beg;
                for i: 0..mask_elems-1 { sm[i] = cast(s32) idx; idx += 1; }
                vv = icb_shuffle_s32(vv, NONE, sm, tprint("%.extract", vname(svi)));
                beg = 0;
            }
            per := tgt_bw / src_elem_bw;
            beg /= per;
            bcv: Value_Id = NONE;
            for nbc_keys if it == cast_src_ty { bcv = nbc_vals[it_index]; break; }
            if bcv == NONE {
                bcv = icb_cast(.BITCAST, vv, cast_src_ty, tprint("%.bc", vname(svi)));
                array_add(*nbc_keys, cast_src_ty); array_add(*nbc_vals, bcv);
            }
            ext := icb_extract_element(bcv, const_int(ir.t_i64, beg), tprint("%.extract", vname(svi)));
            ic_replace_inst_uses_with(bc, ext);
            made_change = true;
        }
    }
    lhs_shuf: Value_Id = ifx is_inst(lhs) && inst_op(lhs) == .SHUFFLEVECTOR then lhs else NONE;
    rhs_shuf: Value_Id = ifx is_inst(rhs) && inst_op(rhs) == .SHUFFLEVECTOR then rhs else NONE;
    if lhs_shuf != NONE && !pm_poison(op(lhs_shuf, 1)) && !pm_poison(rhs) lhs_shuf = NONE;
    if rhs_shuf != NONE && !pm_poison(op(rhs_shuf, 1)) rhs_shuf = NONE;
    if lhs_shuf == NONE && rhs_shuf == NONE return ifx made_change then svi else NONE;
    lhs_op0: Value_Id = NONE; lhs_op1: Value_Id = NONE; rhs_op0: Value_Id = NONE;
    lhs_op0_width: s64 = 0; rhs_op0_width: s64 = 0;
    if lhs_shuf != NONE { lhs_op0 = op(lhs_shuf, 0); lhs_op1 = op(lhs_shuf, 1); lhs_op0_width = cast(s64) vec_count(vtype(lhs_op0)); }
    if rhs_shuf != NONE { rhs_op0 = op(rhs_shuf, 0); rhs_op0_width = cast(s64) vec_count(vtype(rhs_op0)); }
    new_lhs := lhs; new_rhs := rhs;
    if lhs_shuf != NONE {
        if pm_poison(rhs) { new_lhs = lhs_op0; new_rhs = lhs_op1; }
        else if lhs_op0_width == lhs_width new_lhs = lhs_op0;
    }
    if rhs_shuf != NONE && rhs_op0_width == lhs_width new_rhs = rhs_op0;
    if lhs_op0 == rhs_op0 { new_lhs = lhs_op0; new_rhs = NONE; }
    if new_lhs == lhs && new_rhs == rhs return ifx made_change then svi else NONE;
    lhs_mask: [..] s32; lhs_mask.allocator = temp;
    rhs_mask: [..] s32; rhs_mask.allocator = temp;
    if new_lhs != lhs lhs_mask = shuf_mask(lhs_shuf);
    if rhs_shuf != NONE && new_rhs != rhs rhs_mask = shuf_mask(rhs_shuf);
    new_lhs_width := ifx new_lhs != lhs then lhs_op0_width else lhs_width;
    new_mask: [..] s32; new_mask.allocator = temp;
    is_splat := true;
    splat_elt: s64 = -1;
    for i: 0..vwidth-1 {
        elt: s64;
        if mask[i] < 0 elt = -1;
        else if mask[i] < lhs_width {
            if new_lhs != lhs {
                elt = lhs_mask[mask[i]];
                if elt >= lhs_op0_width && vkind(lhs_op1) == .C_POISON elt = -1;
            } else elt = mask[i];
        } else {
            if pm_poison(rhs) elt = -1;
            else if new_rhs != rhs {
                elt = rhs_mask[mask[i] - lhs_width];
                if elt >= rhs_op0_width elt = -1;
            } else elt = mask[i] - lhs_width;
            if elt >= 0 && new_rhs != NONE && new_lhs != new_rhs elt += new_lhs_width;
        }
        if elt >= 0 {
            if splat_elt >= 0 && splat_elt != elt is_splat = false;
            splat_elt = elt;
        }
        array_add(*new_mask, cast(s32) elt);
    }
    if is_splat || masks_eq(new_mask, lhs_mask) || masks_eq(new_mask, rhs_mask) || masks_eq(new_mask, mask) {
        if new_rhs == NONE new_rhs = const_poison(vtype(new_lhs));
        return create_shuffle_s32(new_lhs, new_rhs, new_mask);
    }
    return ifx made_change then svi else NONE;
}

// isDeInterleaveMaskOfFactor
is_deinterleave_mask_of_factor :: (mask: [] s32, factor: u32) -> (bool, u32) {
    for idx: 0..factor-1 {
        ok := true;
        for mask if it >= 0 && cast,no_check(u32) it != idx + cast(u32) it_index * factor { ok = false; break; }
        if ok return true, idx;
    }
    return false, 0;
}

// foldExtractionOfVectorDeinterleave
ic_fold_extraction_of_vector_deinterleave :: (root: Value_Id) -> Value_Id {
    if dl.big_endian return NONE;
    src := op(root, 0);
    div: Value_Id = NONE; svi: Value_Id = NONE; di: Value_Id = NONE;
    if is_inst(src) && inst_op(src) == .EXTRACTVALUE && call_iid(op(src, 0)) == IID_VECTOR_DEINTERLEAVE2 {
        di = op(src, 0); div = call_arg(di, 0);
    } else if is_inst(src) && inst_op(src) == .SHUFFLEVECTOR {
        svi = src;
    } else return NONE;
    is_deinterleave_shuffle :: (i: Value_Id) -> (Value_Id, u32) {
        if !is_inst(i) || inst_op(i) != .SHUFFLEVECTOR || !pm_undef(op(i, 1)) || type_kind(vtype(op(i, 0))) != .VECTOR return NONE, 0xFFFF_FFFF;
        v := op(i, 0);
        n := cast(s64) vec_count(vtype(v));
        m := shuf_mask(i);
        ok, index := is_deinterleave_mask_of_factor(m, 2);
        if ok && index < 2 && svm_is_single_source(m, n) && m.count * 2 == n return v, index;
        return NONE, 0xFFFF_FFFF;
    }
    if svi != NONE {
        div = is_deinterleave_shuffle(svi);
        if div == NONE return NONE;
    } else {
        u := ir.v_first_use[di];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(us) || inst_op(us) != .EXTRACTVALUE || inst(us).nidx != 1 return NONE;
        }
    }
    in_ty := vtype(div);
    if !is_vector_type(in_ty) return NONE;
    et := type_elem(in_ty);
    if !is_int_type(et) return NONE;
    if (vec_count(in_ty) & 1) != 0 return NONE;
    Field :: struct { i: Value_Id; idx: u32; }
    fields: [..] Field; fields.allocator = temp;
    if svi != NONE {
        u := ir.v_first_use[div];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(us) continue;
            v, index := is_deinterleave_shuffle(us);
            if v != div continue;
            if inst_block(us) != inst_block(svi) continue;
            if us != svi && comes_before(us, svi) svi = us;
            array_add(*fields, .{us, index});
        }
    } else {
        u := ir.v_first_use[di];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            array_add(*fields, .{us, ir.u32_pool[inst(us).idx]});
        }
    }
    repl: [..] Field; repl.allocator = temp;
    for f: fields {
        u := ir.v_first_use[f.i];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(us) || inst_op(us) != .ZEXT return NONE;
            st := vtype(op(us, 0));
            ext := type_vector(vec_count(st), type_int(cast(u64) type_int_width(type_elem(st)) * 2), type_kind(st) == .SVECTOR);
            if vtype(us) != ext return NONE;
            array_add(*repl, .{us, f.idx});
        }
    }
    icb_set_insert_point(ifx di != NONE then di else svi);
    w := cast(u64) type_int_width(et);
    bt := type_vector(vec_count(in_ty) / 2, type_int(w * 2), type_kind(in_ty) == .SVECTOR);
    fr := icb_freeze(div);
    bc := icb_cast(.BITCAST, fr, bt);
    m := const_int_ap(bt, ap_low_bits_set(cast(u32)(w * 2), cast(u32) w));
    f0 := icb_and(bc, m);
    f1 := icb_lshr(bc, const_int_of(bt, w));
    for repl {
        ic_replace_inst_uses_with(it.i, ifx it.idx != 0 then f1 else f0);
        wl_add(it.i);
    }
    return root;
}
