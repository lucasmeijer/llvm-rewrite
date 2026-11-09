// SLPVectorizer: gather (buildvector) nodes as shuffles. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (BaseShuffleAnalysis: isIdentityMask, combineMasks, peekThroughShuffles, createShuffle,
// transformMaskAfterShuffle; BoUpSLP::ShuffleCostEstimator; BoUpSLP::processBuildVector).
//
// processBuildVector is a template over the shuffle builder in LLVM (ShuffleCostEstimator for the cost model,
// ShuffleInstructionBuilder for codegen). Here it is one procedure over `Bv_Builder`, whose `kind` selects the
// behaviour of every builder call (a switch at each call, DESIGN.md "No hand-rolled vtables"). Only the cost kind
// exists so far; codegen (ShuffleInstructionBuilder) is the next stage of the port.
//
// PointerUnion<Value *, const TreeEntry *> is `Pu` (v or te set, both unset = null).

Pu :: struct { v: Value_Id = NONE; te: Te_Id = TE_NONE; }
pu_v :: (v: Value_Id) -> Pu { p: Pu; p.v = v; return p; }
pu_te :: (te: Te_Id) -> Pu { p: Pu; p.te = te; return p; }
pu_null :: (p: Pu) -> bool { return p.v == NONE && p.te == TE_NONE; }

Bv_Kind :: enum u8 { COST; }

Bv_Builder :: struct {
    kind: Bv_Kind;
    sty: Type_Id;
    is_finalized: bool;
    common_mask: [..] s32;
    in_vectors: [..] Pu;
    // ShuffleCostEstimator
    bv_engaged := true;
    bv_values: [..] Value_Id;
    cost: Cost;
    vectorized_vals: [..] Value_Id;     // SmallDenseSet (membership)
    checked_extracts: *[..] Value_Id;   // SmallPtrSet (membership)
    same_nodes_estimated := true;
}

bv_init_cost :: (b: *Bv_Builder, sty: Type_Id, vectorized_vals: [] Value_Id, checked_extracts: *[..] Value_Id) {
    b.* = .{};
    b.kind = .COST;
    b.sty = sty;
    b.common_mask.allocator = temp; b.in_vectors.allocator = temp; b.bv_values.allocator = temp; b.vectorized_vals.allocator = temp;
    for vectorized_vals if !slp_has(b.vectorized_vals, it) array_add(*b.vectorized_vals, it);
    b.checked_extracts = checked_extracts;
}

// ---------------------------------------------------------------- BaseShuffleAnalysis

// getVF(V)
bsa_get_vf :: (sty: Type_Id, v: Value_Id) -> s64 { return cast(s64) (type_count(vtype(v)) / slp_num_elements(sty)); }

// isIdentityMask(Mask, VecTy, IsStrict)
bsa_is_identity_mask :: (mask: [] s32, vf: s64, strict: bool) -> bool {
    limit := mask.count;
    if vf == limit && svm_is_identity(mask, limit) return true;
    if !strict {
        ok, idx := svm_is_extract_subvector(mask, vf);
        if ok && idx == 0 return true;
        if vf > 0 && limit % vf == 0 {
            all := true;
            for k: 0..limit / vf - 1 {
                sl := array_view(mask, k * vf, vf);
                all_poison := true; for sl if it != PME { all_poison = false; break; }
                if !all_poison && !svm_is_identity(sl, vf) { all = false; break; }
            }
            if all return true;
        }
    }
    return false;
}
// combineMasks(LocalVF, Mask, ExtMask)
bsa_combine_masks :: (local_vf: s64, mask: *[..] s32, ext_mask: [] s32) {
    vf := mask.count;
    nm := new_mask(ext_mask.count);
    for i: 0..ext_mask.count-1 {
        if ext_mask[i] == PME continue;
        mi := mask.*[ext_mask[i] % vf];
        nm[i] = ifx mi == PME then PME else cast(s32) (mi % local_vf);
    }
    mask.* = nm;
}
is_shuffle_inst :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .SHUFFLEVECTOR; }

// peekThroughShuffles(V, Mask, SinglePermute)
bsa_peek_through_shuffles :: (v: *Value_Id, mask: *[..] s32, single_permute: bool) -> bool {
    o := v.*;
    identity_op: Value_Id = NONE;
    identity_mask := new_mask();
    while is_shuffle_inst(o) {
        sv := o;
        svty := vtype(sv);
        if type_kind(svty) != .VECTOR break;
        svn := cast(s64) type_count(svty);
        if bsa_is_identity_mask(mask.*, svn, false) {
            if identity_op == NONE || !single_permute ||
               (bsa_is_identity_mask(mask.*, svn, true) && !svm_is_zero_elt_splat(identity_mask, identity_mask.count)) {
                identity_op = sv;
                identity_mask = mask_copy(mask.*);
            }
        }
        if sv_is_zero_elt_splat(sv) {
            identity_op = sv;
            identity_mask = mask_copy(mask.*);
        }
        local_vf := mask.count;
        if type_kind(vtype(op(sv, 0))) == .VECTOR local_vf = cast(s64) type_count(vtype(op(sv, 0)));
        svm := shuffle_mask_s32(sv);
        ext := new_mask(mask.count);
        for i, idx: mask.* {
            if i == PME || i >= svm.count continue;
            ext[idx] = svm[i];
        }
        op1_undef := all_bits(slp_is_undef_vector(op(sv, 0), slp_build_use_mask(local_vf, ext, SLP_USE_MASK_FIRST_ARG), true));
        op2_undef := all_bits(slp_is_undef_vector(op(sv, 1), slp_build_use_mask(local_vf, ext, SLP_USE_MASK_SECOND_ARG), true));
        if !op1_undef && !op2_undef {
            for * i: mask.* {
                if i.* == PME continue;
                if svm[i.* % svm.count] == PME i.* = PME;
            }
            break;
        }
        sm := mask_copy(svm);
        bsa_combine_masks(local_vf, *sm, mask.*);
        mask.* = sm;
        o = ifx op2_undef then op(sv, 0) else op(sv, 1);
    }
    oty := vtype(o);
    if type_kind(oty) != .VECTOR || !bsa_is_identity_mask(mask.*, cast(s64) type_count(oty), single_permute) || svm_is_zero_elt_splat(mask.*, mask.count) {
        if identity_op != NONE {
            v.* = identity_op;
            for idx, i: mask.* if idx == PME identity_mask[i] = PME;
            mask.* = identity_mask;
            if !single_permute return false;
            if bsa_is_identity_mask(mask.*, cast(s64) type_count(vtype(identity_op)), true) return true;
            if is_shuffle_inst(identity_op) {
                ism := shuffle_mask_s32(identity_op);
                if mask.count == ism.count && sv_is_zero_elt_splat(identity_op) && svm_is_zero_elt_splat(mask.*, mask.count) {
                    ok := true;
                    for m, i: mask.* if m != PME && ism[i] != 0 { ok = false; break; }
                    if ok return true;
                }
            }
            return false;
        }
        v.* = o;
        return false;
    }
    v.* = o;
    return true;
}

// ShuffleCostBuilder::isEmptyOrIdentity
scb_is_empty_or_identity :: (mask: [] s32, vf: s64) -> bool {
    if mask.count == 0 return true;
    if vf == mask.count && svm_is_identity(mask, vf) return true;
    ok, idx := svm_is_extract_subvector(mask, vf);
    return ok && idx == 0;
}

// BaseShuffleAnalysis::createShuffle<InstructionCost>(V1, V2, Mask, ShuffleCostBuilder, ScalarTy, VL)
bsa_create_shuffle_cost :: (v1_in: Value_Id, v2_in: Value_Id, mask_in: [] s32, sty: Type_Id, vl: [] Value_Id) -> Cost {
    v1 := v1_in; v2 := v2_in;
    if slp_num_elements(sty) != 1 slp_fail("REVEC shuffles");
    mask := mask_copy(mask_in);
    vf := mask.count;
    if type_kind(vtype(v1)) == .VECTOR vf = cast(s64) type_count(vtype(v1));
    if v2 != NONE && !all_bits(slp_is_undef_vector(v2, slp_build_use_mask(vf, mask, SLP_USE_MASK_SECOND_ARG), true)) {
        op1 := v1; op2 := v2;
        vf1 := cast(s64) type_count(vtype(v1));
        cm1 := new_mask(mask.count); cm2 := new_mask(mask.count);
        for i: 0..mask.count-1 {
            if mask[i] < vf1 cm1[i] = mask[i];
            else cm2[i] = mask[i] - cast(s32) vf1;
        }
        while true {
            prev1 := op1; prev2 := op2;
            bsa_peek_through_shuffles(*op1, *cm1, false);
            bsa_peek_through_shuffles(*op2, *cm2, false);
            if is_shuffle_inst(op1) && is_shuffle_inst(op2) {
                sv1 := op1; sv2 := op2;
                m1 := shuffle_mask_s32(sv1); m2 := shuffle_mask_s32(sv2);
                ext1 := new_mask(mask.count);
                for i, idx: cm1 if i != PME ext1[idx] = m1[i];
                um1 := slp_build_use_mask(cast(s64) type_count(vtype(op(sv1, 1))), ext1, SLP_USE_MASK_SECOND_ARG);
                ext2 := new_mask(cm2.count);
                for i, idx: cm2 if i != PME ext2[idx] = m2[i];
                um2 := slp_build_use_mask(cast(s64) type_count(vtype(op(sv2, 1))), ext2, SLP_USE_MASK_SECOND_ARG);
                if vtype(op(sv1, 0)) == vtype(op(sv2, 0)) && vtype(op(sv1, 0)) != vtype(sv1) &&
                   all_bits(slp_is_undef_vector(op(sv1, 1), um1)) && all_bits(slp_is_undef_vector(op(sv2, 1), um2)) {
                    op1 = op(sv1, 0); op2 = op(sv2, 0);
                    sm1 := mask_copy(m1);
                    lvf := sm1.count;
                    if type_kind(vtype(op1)) == .VECTOR lvf = cast(s64) type_count(vtype(op1));
                    bsa_combine_masks(lvf, *sm1, cm1);
                    cm1 = sm1;
                    sm2 := mask_copy(m2);
                    lvf = sm2.count;
                    if type_kind(vtype(op2)) == .VECTOR lvf = cast(s64) type_count(vtype(op2));
                    bsa_combine_masks(lvf, *sm2, cm2);
                    cm2 = sm2;
                }
            }
            if prev1 == op1 && prev2 == op2 break;
        }
        vfm := max(cast(s64) type_count(vtype(op1)), cast(s64) type_count(vtype(op2)));
        for i: 0..mask.count-1 {
            if cm2[i] != PME cm1[i] = cm2[i] + cast(s32) (ifx op1 == op2 then 0 else vfm);
        }
        if op1 == op2 && (svm_is_identity(cm1, vfm) ||
                          (svm_is_zero_elt_splat(cm1, vfm) && is_shuffle_inst(op1) && masks_equal(shuffle_mask_s32(op1), cm1)))
            return TCC_FREE;
        // ShuffleCostBuilder::createShuffleVector(V1, V2, Mask)
        n := cast(s64) type_count(vtype(op1));
        if scb_is_empty_or_identity(cm1, n) return TCC_FREE;
        return slp_shuffle_cost(SK_PERMUTE_TWO_SRC, vtype(op1), cm1);
    }
    if pm_poison(v1) return TCC_FREE;
    is_identity := bsa_peek_through_shuffles(*v1, *mask, true);
    if is_identity return TCC_FREE;
    n := cast(s64) type_count(vtype(v1));
    if scb_is_empty_or_identity(mask, n) return TCC_FREE;
    return slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, vtype(v1), mask, TCK_RECIP_THROUGHPUT, 0, NONE, vl);
}
masks_equal :: (a: [] s32, b: [] s32) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}
// transformMaskAfterShuffle(CommonMask, Mask)
bsa_transform_mask_after_shuffle :: (common: *[..] s32, mask: [] s32) {
    for i: 0..common.count-1 if mask[i] != PME common.*[i] = cast(s32) i;
}

// ---------------------------------------------------------------- ShuffleCostEstimator

// getAllOnesValue(DL, Ty)
sce_all_ones_value :: (ty: Type_Id) -> Value_Id {
    st := scalar_type(ty);
    if type_kind(st) == .PTR {
        r := ce_cast(.INTTOPTR, cf_all_ones(type_int(cast(u32) (dl_type_store_size(st) * 8))), st);
        if is_vector_type(ty) r = cf_get_splat(ty, r);
        return r;
    }
    return cf_all_ones(ty);
}

// getBuildVectorCost(VL, Root)
sce_build_vector_cost :: (b: *Bv_Builder, vl: [] Value_Id, root: Value_Id) -> Cost {
    all_undef := true; for vl if !pm_undef_value(it) { all_undef = false; break; }
    if (root == NONE && slp_all_constant(vl)) || all_undef return TCC_FREE;
    vec_ty := slp_widened_type(b.sty, cast(u64) vl.count);
    if root == NONE && slp_is_splat(vl) {
        it_idx := 0;
        for vl if !pm_undef_value(it) { it_idx = it_index; break; }
        x := vl[it_idx];
        cnt := 0; for vl if it == x cnt += 1;
        rest_undef := true; for k: 1..vl.count-1 if !pm_undef_value(vl[k]) { rest_undef = false; break; }
        need_shuffle := cnt > 1 && (vl[0] != x || !rest_undef);
        if !need_shuffle return tti_vector_instr_cost(slp.tti, .INSERTELEMENT, vec_ty, TCK_RECIP_THROUGHPUT, cast(u32) it_idx, const_poison(vec_ty), x);
        sm := new_mask(vl.count);
        for v, i: vl sm[i] = ifx pm_poison(v) then PME else cast(s32) 0;
        ins := tti_vector_instr_cost(slp.tti, .INSERTELEMENT, vec_ty, TCK_RECIP_THROUGHPUT, 0, const_poison(vec_ty), x);
        a: [1] Value_Id; a[0] = x;
        return cost_add(ins, slp_shuffle_cost(SK_BROADCAST, vec_ty, sm, TCK_RECIP_THROUGHPUT, 0, NONE, a));
    }
    return slp_get_gather_cost(vl, root == NONE, b.sty);
}

// computeExtractCost(VL, Mask, ShuffleKinds, NumParts)
sce_compute_extract_cost :: (b: *Bv_Builder, vl: [] Value_Id, mask: [] s32, kinds: [] s64, num_parts: u64) -> Cost {
    num_elts: s64 = 0;
    for v: vl {
        if !is_inst(v) || inst_op(v) != .EXTRACTELEMENT continue;
        vt := vtype(op(v, 0));
        if type_kind(vt) != .VECTOR continue;
        num_elts = max(num_elts, cast(s64) type_count(vt));
    }
    epv := cast(s64) slp_part_num_elems(cast(u64) vl.count, num_parts);
    check_per_registers_shuffle :: (m: *[..] s32, indices: *[..] s64, sub_sizes: *[..] s64, num_elts: s64, epv: s64, num_parts: s64) -> s64 {
        if num_elts <= epv return SK_NONE;
        mn: s64 = 0x7FFF_FFFF;
        for m.* if it != PME mn = min(mn, cast(s64) it);
        offset_reg0 := (mn / epv) * epv;
        offset_reg1 := offset_reg0;
        reg_ids: [..] s64; reg_ids.allocator = temp;
        kind := SK_PERMUTE_SINGLE_SRC;
        first_reg := -1;
        array_reset_keeping_memory(indices);
        array_add(indices, offset_reg0);
        for * i, pos: m.* {
            if i.* == PME continue;
            idx := cast(s64) i.* - offset_reg0;
            reg := (idx / num_elts) * num_parts + (idx % num_elts) / epv;
            if first_reg < 0 first_reg = reg;
            if !slp_has(reg_ids, reg) array_add(*reg_ids, reg);
            if reg_ids.count > 2 return SK_NONE;
            if reg_ids.count == 2 {
                kind = SK_PERMUTE_TWO_SRC;
                if indices.count == 1 {
                    mn2: s64 = 0x7FFF_FFFF;
                    for k: pos..m.count-1 {
                        x := m.*[k];
                        if x == PME continue;
                        r := ((cast(s64) x - offset_reg0) / num_elts) * num_parts + ((cast(s64) x - offset_reg0) % num_elts) / epv;
                        if r == first_reg continue;
                        mn2 = min(mn2, cast(s64) x);
                    }
                    offset_reg1 = (mn2 / epv) * epv;
                    index := offset_reg1 % num_elts;
                    array_add(indices, index);
                    array_add(sub_sizes, min(num_elts - index, epv));
                }
                idx = cast(s64) i.* - offset_reg1;
            }
            i.* = cast(s32) ((idx % num_elts) % epv + ifx reg == first_reg then 0 else epv);
        }
        return kind;
    }
    cost: Cost = 0;
    for part: 0..cast(s64) num_parts - 1 {
        if kinds[part] == SK_NONE continue;
        ms := array_view(mask, part * epv, cast(s64) slp_num_elems(cast(u64) mask.count, cast(u64) epv, cast(u64) part));
        sub := new_mask(epv);
        for ms sub[it_index] = it;
        indices: [..] s64; indices.allocator = temp;
        sub_sizes: [..] s64; sub_sizes.allocator = temp;
        rk := check_per_registers_shuffle(*sub, *indices, *sub_sizes, num_elts, epv, cast(s64) num_parts);
        if rk == SK_NONE {
            if kinds[part] != SK_PERMUTE_SINGLE_SRC || !svm_is_identity(ms, max(num_elts, ms.count))
                cost = cost_add(cost, slp_shuffle_cost(kinds[part], slp_widened_type(b.sty, cast(u64) num_elts), ms));
            continue;
        }
        if rk != SK_PERMUTE_SINGLE_SRC || !svm_is_identity(sub, epv)
            cost = cost_add(cost, slp_shuffle_cost(rk, slp_widened_type(b.sty, cast(u64) epv), sub));
        base_vf := slp_full_vector_number_of_elements(slp.tti, vtype(vl[0]), cast(u64) (((num_elts + epv - 1) / epv) * epv));
        for idx, k: indices {
            if k >= sub_sizes.count break;
            cost = cost_add(cost, slp_shuffle_cost(SK_EXTRACT_SUBVECTOR, slp_widened_type(b.sty, base_vf), .[], TCK_RECIP_THROUGHPUT, idx,
                                                   slp_widened_type(b.sty, cast(u64) sub_sizes[k])));
        }
        sub = new_mask(num_elts);
        for ms sub[it_index] = it;
        orig := slp_shuffle_cost(kinds[part], slp_widened_type(b.sty, cast(u64) num_elts), sub);
        if orig < cost cost = orig;
    }
    return cost;
}

pu_eq :: (a: Pu, b: Pu) -> bool { return a.v == b.v && a.te == b.te; }

// estimateNodesPermuteCost(E1, E2, Mask, Part, SliceSize)
sce_estimate_nodes_permute_cost :: (b: *Bv_Builder, e1: Te_Id, e2: Te_Id, mask: [] s32, part: s64, slice_size: s64) {
    if b.same_nodes_estimated {
        if (b.in_vectors.count == 2 && b.in_vectors[0].te == e1 && b.in_vectors[1].te == e2) ||
           (e2 == TE_NONE && b.in_vectors[0].te == e1) {
            limit := cast(s64) slp_num_elems(cast(u64) mask.count, cast(u64) slice_size, cast(u64) part);
            for k: 0..limit-1 b.common_mask[slice_size * part + k] = mask[part * slice_size + k];
            return;
        }
        b.cost = cost_add(b.cost, sce_create_shuffle(b, b.in_vectors[0], ifx b.in_vectors.count == 1 then Pu.{} else b.in_vectors[1], b.common_mask));
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
    } else if b.in_vectors.count == 2 {
        b.cost = cost_add(b.cost, sce_create_shuffle(b, b.in_vectors[0], b.in_vectors[1], b.common_mask));
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
    }
    b.same_nodes_estimated = false;
    if e2 == TE_NONE && b.in_vectors.count == 1 {
        vf := te_vector_factor(e1);
        f := b.in_vectors[0];
        if f.v != NONE vf = max(vf, bsa_get_vf(b.sty, f.v));
        else vf = max(vf, te_vector_factor(f.te));
        for idx: 0..b.common_mask.count-1
            if mask[idx] != PME && b.common_mask[idx] == PME b.common_mask[idx] = mask[idx] + cast(s32) vf;
        b.cost = cost_add(b.cost, sce_create_shuffle(b, b.in_vectors[0], pu_te(e1), b.common_mask));
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
    } else {
        p := b.in_vectors[0];
        b.cost = cost_add(b.cost, sce_create_shuffle(b, pu_te(e1), ifx e2 == TE_NONE then Pu.{} else pu_te(e2), mask));
        vf := mask.count;
        if p.v != NONE vf = max(vf, cast(s64) slp_num_elements(vtype(p.v)));
        else vf = max(vf, te_vector_factor(p.te));
        for idx: 0..b.common_mask.count-1
            if mask[idx] != PME b.common_mask[idx] = cast(s32) (idx + ifx b.in_vectors.count == 0 then 0 else vf);
        b.cost = cost_add(b.cost, sce_create_shuffle(b, p, b.in_vectors[0], b.common_mask));
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
    }
}

// GetNodeMinBWAffectedCost(E, VF)
sce_node_min_bw_cost :: (b: *Bv_Builder, te: Te_Id, vf: s64) -> Cost {
    e := *slp.entries[te];
    if te_is_gather(te) && slp_all_constant(e.scalars) return TCC_FREE;
    esty := vtype(e.scalars[0]);
    signed := true;
    found, bw := slp_min_bw_of(te);
    if found { esty = type_int(cast(u32) bw.bits); signed = bw.signed; }
    if esty != b.sty {
        opc: Opcode = .TRUNC;
        dst_sz := dl_type_size_bits(b.sty); src_sz := dl_type_size_bits(esty);
        if dst_sz > src_sz opc = ifx signed then .SEXT else .ZEXT;
        return tti_cast_cost(slp.tti, opc, slp_widened_type(b.sty, cast(u64) vf), slp_widened_type(esty, cast(u64) vf), CCH_NONE, TCK_RECIP_THROUGHPUT);
    }
    return TCC_FREE;
}
// GetValueMinBWAffectedCost(V)
sce_value_min_bw_cost :: (b: *Bv_Builder, v: Value_Id) -> Cost {
    if is_const(v) return TCC_FREE;
    vt := vtype(v);
    esty := type_elem(vt);
    if esty != b.sty {
        signed := !is_known_non_negative(v, slp_simple_query());
        opc: Opcode = .TRUNC;
        dst_sz := dl_type_size_bits(b.sty); src_sz := dl_type_size_bits(esty);
        if dst_sz > src_sz opc = ifx signed then .SEXT else .ZEXT;
        return tti_cast_cost(slp.tti, opc, type_vector(type_count(vt), b.sty, false), vt, CCH_NONE, TCK_RECIP_THROUGHPUT);
    }
    return TCC_FREE;
}

// ShuffleCostEstimator::createShuffle(P1, P2, Mask, VL)
sce_create_shuffle :: (b: *Bv_Builder, p1: Pu, p2: Pu, mask: [] s32, vl: [] Value_Id = .[]) -> Cost {
    cm := mask_copy(mask);
    v1 := p1.v; v2 := p2.v;
    common_vf := mask.count;
    extra: Cost = 0;
    sty := b.sty;
    if v1 == NONE && v2 == NONE && !pu_null(p2) {
        e := p1.te; e2 := p2.te;
        vf := te_vector_factor(e);
        common_vf = max(vf, te_vector_factor(e2));
        if slp.entries[e].scalars.count == slp.entries[e2].scalars.count {
            em := te_common_mask(e); e2m := te_common_mask(e2);
            if em.count || e2m.count {
                for * idx: cm {
                    if idx.* == PME continue;
                    if idx.* < common_vf && em.count idx.* = em[idx.*];
                    else if idx.* >= common_vf
                        idx.* = (ifx e2m.count == 0 then idx.* - cast(s32) common_vf else e2m[idx.* - common_vf]) + cast(s32) slp.entries[e].scalars.count;
                }
            }
            common_vf = slp.entries[e].scalars.count;
            extra = cost_add(extra, cost_add(sce_node_min_bw_cost(b, e, common_vf), sce_node_min_bw_cost(b, e2, common_vf)));
        } else {
            extra = cost_add(extra, cost_add(sce_node_min_bw_cost(b, e, te_vector_factor(e)), sce_node_min_bw_cost(b, e2, te_vector_factor(e2))));
        }
        v1 = const_null_value(slp_widened_type(sty, cast(u64) common_vf));
        v2 = sce_all_ones_value(slp_widened_type(sty, cast(u64) common_vf));
    } else if v1 == NONE && pu_null(p2) {
        e := p1.te;
        ee := *slp.entries[e];
        vf := te_vector_factor(e);
        common_vf = vf;
        if ee.scalars.count == mask.count && vf != mask.count {
            em := te_common_mask(e);
            for * idx: cm if idx.* != PME idx.* = em[idx.*];
            common_vf = ee.scalars.count;
        } else if ee.interleave_factor > 0 && ee.scalars.count != mask.count && svm_is_deinterleave_mask_of_factor(cm, ee.interleave_factor) {
            for * idx, i: cm idx.* = cast(s32) i;
        }
        extra = cost_add(extra, sce_node_min_bw_cost(b, e, common_vf));
        v1 = const_null_value(slp_widened_type(sty, cast(u64) common_vf));
        if ee.reorder_indices.count && common_vf == ee.reorder_indices.count && common_vf == cm.count {
            any_non_id := false; for m, i: cm if m != PME && m != cast(s32) i { any_non_id = true; break; }
            any_non_zero := false; for m: cm if m != PME && m != 0 { any_non_zero = true; break; }
            if any_non_id && any_non_zero {
                rm := slp_inverse_permutation(ee.reorder_indices);
                slp_add_mask(*cm, rm);
            }
        }
    } else if v1 != NONE && pu_null(p2) {
        extra = cost_add(extra, sce_value_min_bw_cost(b, v1));
        common_vf = bsa_get_vf(sty, v1);
    } else if v1 != NONE && v2 == NONE {
        vf := bsa_get_vf(sty, v1);
        e2 := p2.te;
        common_vf = max(vf, te_vector_factor(e2));
        if slp.entries[e2].scalars.count == vf && vf != common_vf {
            e2m := te_common_mask(e2);
            for * idx: cm {
                if idx.* == PME continue;
                if idx.* >= common_vf idx.* = e2m[idx.* - common_vf] + cast(s32) vf;
            }
            common_vf = vf;
        }
        extra = cost_add(extra, sce_value_min_bw_cost(b, v1));
        v1 = const_null_value(slp_widened_type(sty, cast(u64) common_vf));
        extra = cost_add(extra, sce_node_min_bw_cost(b, e2, min(common_vf, te_vector_factor(e2))));
        v2 = sce_all_ones_value(slp_widened_type(sty, cast(u64) common_vf));
    } else if v1 == NONE && v2 != NONE {
        vf := bsa_get_vf(sty, v2);
        e1 := p1.te;
        common_vf = max(vf, te_vector_factor(e1));
        if slp.entries[e1].scalars.count == vf && vf != common_vf {
            e1m := te_common_mask(e1);
            for * idx: cm {
                if idx.* == PME continue;
                if idx.* >= common_vf idx.* = e1m[idx.* - common_vf] + cast(s32) vf;
                else idx.* = e1m[idx.*];
            }
            common_vf = vf;
        }
        extra = cost_add(extra, sce_node_min_bw_cost(b, e1, min(common_vf, te_vector_factor(e1))));
        v1 = const_null_value(slp_widened_type(sty, cast(u64) common_vf));
        extra = cost_add(extra, sce_value_min_bw_cost(b, v2));
        v2 = sce_all_ones_value(slp_widened_type(sty, cast(u64) common_vf));
    } else {
        vf := bsa_get_vf(sty, v1);
        common_vf = max(vf, bsa_get_vf(sty, v2));
        extra = cost_add(extra, cost_add(sce_value_min_bw_cost(b, v1), sce_value_min_bw_cost(b, v2)));
        if vtype(v1) != vtype(v2) {
            v1 = const_null_value(slp_widened_type(sty, cast(u64) common_vf));
            v2 = sce_all_ones_value(slp_widened_type(sty, cast(u64) common_vf));
        } else {
            if type_elem(vtype(v1)) != sty v1 = const_null_value(slp_widened_type(sty, cast(u64) common_vf));
            if type_elem(vtype(v2)) != sty v2 = sce_all_ones_value(slp_widened_type(sty, cast(u64) common_vf));
        }
    }
    b.in_vectors[0] = pu_v(const_null_value(slp_widened_type(sty, cast(u64) cm.count)));
    if b.in_vectors.count == 2 pop(*b.in_vectors);
    return cost_add(extra, bsa_create_shuffle_cost(v1, v2, cm, sty, vl));
}

// slice of the gathered values for the extracts: E->Scalars reordered by ReorderIndices
// adjustExtracts(E, Mask, ShuffleKinds, NumParts, UseVecBaseAsInput)
sce_adjust_extracts :: (b: *Bv_Builder, te: Te_Id, mask: [] s32, kinds: [] s64, num_parts: u64) -> (Value_Id, bool) {
    use_vec_base := false;
    if mask.count == 0 return NONE, false;
    e := *slp.entries[te];
    vec_base: Value_Id = NONE;
    vl := vl_copy(e.scalars);
    if e.reorder_indices.count {
        rm := new_mask(); for e.reorder_indices array_add(*rm, cast(s32) it);
        slp_reorder_scalars(*vl, rm);
    }
    prev_found := false;
    for k: 0..te-1 {
        o := cast(Te_Id) k;
        oe := *slp.entries[o];
        if !((te_has_state(o) && !is_alt_shuffle(oe.s) && te_opcode(o) == .EXTRACTELEMENT) || te_is_gather(o)) continue;
        all := true;
        for d, idx: oe.scalars {
            if !(vl.count > idx && (mask[idx] == PME || pm_undef_value(vl[idx]) || d == vl[idx])) { all = false; break; }
        }
        if all { prev_found = true; break; }
    }
    unique_bases: [..] Value_Id; unique_bases.allocator = temp;
    slice := cast(s64) slp_part_num_elems(cast(u64) vl.count, num_parts);
    ops_keys: [..] Value_Id; ops_keys.allocator = temp;   // SmallDenseMap<Value *, APInt>: summed, order irrelevant
    ops_dem: [..] [] bool; ops_dem.allocator = temp;
    for part: 0..cast(s64) num_parts - 1 {
        limit := cast(s64) slp_num_elems(cast(u64) vl.count, cast(u64) slice, cast(u64) part);
        sub_mask := array_view(mask, part * slice, limit);
        for i: 0..limit-1 {
            v := vl[part * slice + i];
            if pm_undef_value(v) || (sub_mask.count && sub_mask[i] == PME) continue;
            ee := v;
            vec_base = op(ee, 0);
            if !slp_has(unique_bases, vec_base) array_add(*unique_bases, vec_base);
            ves := slp_get_tree_entries(v);
            first_check := slp_has(b.checked_extracts.*, v);
            if !first_check array_add(b.checked_extracts, v);
            skip := first_check || !slp_are_all_users_vectorized_set(v, b.vectorized_vals);
            if !skip for ves if table_contains(*slp.deleted_nodes, it) || table_contains(*slp.transformed_to_gather_nodes, it) { skip = true; break; }
            if !skip && e.user_tree_index.user != TE_NONE && e.user_tree_index.edge == EDGE_NONE && !slp_is_vectorized(ee) {
                c1 := 0; for e.scalars if it == ee c1 += 1;
                c2 := 0; for slp.entries[e.user_tree_index.user].scalars if it == ee c2 += 1;
                if c1 != c2 skip = true;
            }
            if !skip {
                u := ir.v_first_use[ee];
                while u != NONE {
                    usr := ir.u_user[u]; u = ir.u_next[u];
                    if is_inst(usr) && inst_op(usr) == .GEP && !slp_are_all_users_vectorized_set(usr, b.vectorized_vals) { skip = true; break; }
                }
            }
            if !skip && ves.count && !slp_has(ves, te) skip = true;
            if skip continue;
            ok, idx := slp_extract_index(ee);
            if !ok continue;
            if has_one_use(ee) || !prev_found {
                ext := first_user(ee);
                if is_inst(ext) && (inst_op(ext) == .SEXT || inst_op(ext) == .ZEXT) && all_users_are_geps(ext) {
                    b.cost = cost_sub(b.cost, tti_extract_with_extend_cost(slp.tti, inst_op(ext), vtype(ext), vtype(op(ee, 0)), cast(u32) idx));
                    b.cost = cost_add(b.cost, tti_cast_cost(slp.tti, inst_op(ext), vtype(ext), vtype(ee), tti_cast_context_hint(ext), TCK_RECIP_THROUGHPUT, ext));
                    continue;
                }
            }
            ki := -1;
            for ops_keys if it == vec_base { ki = it_index; break; }
            if ki < 0 {
                array_add(*ops_keys, vec_base);
                array_add(*ops_dem, NewArray(cast(s64) slp_num_elements(vtype(vec_base)), bool,, temp));
                ki = ops_keys.count - 1;
            }
            ops_dem[ki][idx] = true;
        }
    }
    for vec: ops_keys
        b.cost = cost_sub(b.cost, tti_scalarization_overhead(slp.tti, vtype(vec), ops_dem[it_index], false, true, TCK_RECIP_THROUGHPUT));
    if !prev_found b.cost = cost_add(b.cost, sce_compute_extract_cost(b, vl, mask, kinds, num_parts));
    array_reset_keeping_memory(*b.in_vectors);
    array_add(*b.in_vectors, pu_te(te));
    b.common_mask = mask_copy(mask);
    bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
    b.same_nodes_estimated = false;
    if num_parts != 1 && unique_bases.count != 1 {
        use_vec_base = true;
        vec_base = const_null_value(slp_widened_type(b.sty, cast(u64) b.common_mask.count));
    }
    return vec_base, use_vec_base;
}

// areAllUsersVectorized(I, VectorizedVals) with a non-null set
slp_are_all_users_vectorized_set :: (i: Value_Id, vals: [] Value_Id) -> bool {
    if has_one_use(i) && slp_has(vals, i) return true;
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u]; u = ir.u_next[u];
        if slp_is_vectorized(usr) || slp_is_vector_like_inst_with_const_ops(usr) ||
           (is_inst(usr) && inst_op(usr) == .EXTRACTELEMENT && table_contains(*slp.must_gather, usr)) continue;
        return false;
    }
    return true;
}

// resetForSameNode()
sce_reset_for_same_node :: (b: *Bv_Builder) {
    b.is_finalized = false;
    array_reset_keeping_memory(*b.common_mask);
    array_reset_keeping_memory(*b.in_vectors);
    b.cost = 0;
    array_reset_keeping_memory(*b.vectorized_vals);
    b.same_nodes_estimated = true;
}

// add(E1, E2, Mask)
bv_add_te2 :: (b: *Bv_Builder, e1: Te_Id, e2: Te_Id, mask: [] s32) {
    b.bv_engaged = false;
    if e1 == e2 { bv_add_te(b, e1, mask); return; }
    if b.in_vectors.count == 0 {
        b.common_mask = mask_copy(mask);
        array_add(*b.in_vectors, pu_te(e1)); array_add(*b.in_vectors, pu_te(e2));
        return;
    }
    mvt := slp_widened_type(b.sty, cast(u64) mask.count);
    np := slp_number_of_parts(slp.tti, mvt, b.sty, cast(u64) mask.count);
    slice := cast(s64) slp_part_num_elems(cast(u64) mask.count, np);
    first := mask.count;
    for mask if it != PME { first = it_index; break; }
    sce_estimate_nodes_permute_cost(b, e1, e2, mask, first / slice, slice);
}
// add(E1, Mask)
bv_add_te :: (b: *Bv_Builder, e1: Te_Id, mask: [] s32) {
    b.bv_engaged = false;
    if b.in_vectors.count == 0 {
        b.common_mask = mask_copy(mask);
        array_add(*b.in_vectors, pu_te(e1));
        return;
    }
    mvt := slp_widened_type(b.sty, cast(u64) mask.count);
    np := slp_number_of_parts(slp.tti, mvt, b.sty, cast(u64) mask.count);
    slice := cast(s64) slp_part_num_elems(cast(u64) mask.count, np);
    first := mask.count;
    for mask if it != PME { first = it_index; break; }
    sce_estimate_nodes_permute_cost(b, e1, TE_NONE, mask, first / slice, slice);
    if !b.same_nodes_estimated && b.in_vectors.count == 1 array_add(*b.in_vectors, pu_te(e1));
}
// add(V1, V2, Mask): only for extracts of two vectors, already handled by adjustExtracts
bv_add_v2 :: (b: *Bv_Builder, v1: Value_Id, v2: Value_Id, mask: [] s32) {}
// add(V1, Mask, ForExtracts)
bv_add_v :: (b: *Bv_Builder, v1: Value_Id, mask: [] s32, for_extracts := false) {
    if b.bv_engaged && !is_const(v1) b.bv_engaged = false;
    if b.in_vectors.count == 0 {
        b.common_mask = mask_copy(mask);
        array_add(*b.in_vectors, pu_v(v1));
        return;
    }
    if for_extracts return;
    vf := bsa_get_vf(b.sty, v1);
    if b.in_vectors.count == 2 {
        b.cost = cost_add(b.cost, sce_create_shuffle(b, b.in_vectors[0], b.in_vectors[1], b.common_mask));
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
        vf = max(vf, b.common_mask.count);
    } else if b.in_vectors[0].te != TE_NONE {
        vf = max(vf, te_vector_factor(b.in_vectors[0].te));
    } else {
        vf = max(vf, cast(s64) type_count(vtype(b.in_vectors[0].v)));
    }
    array_add(*b.in_vectors, pu_v(v1));
    for idx: 0..b.common_mask.count-1
        if mask[idx] != PME && b.common_mask[idx] == PME b.common_mask[idx] = mask[idx] + cast(s32) vf;
}
// gather(VL, MaskVF, Root)
bv_gather :: (b: *Bv_Builder, vl: [] Value_Id, mask_vf: s64 = 0, root: Value_Id = NONE) -> Value_Id {
    b.cost = cost_add(b.cost, sce_build_vector_cost(b, vl, root));
    if b.bv_engaged {
        if b.bv_values.count == 0 && b.in_vectors.count == 0 { for vl array_add(*b.bv_values, it); }
        else b.bv_engaged = false;
    }
    if root == NONE {
        vf := vl.count;
        if mask_vf != 0 vf = min(vf, mask_vf);
        vsty := vtype(vl[0]);
        if is_vector_type(vsty) slp_fail("REVEC gathers");
        vals: [..] Value_Id; vals.allocator = temp;
        for k: 0..vf-1 {
            v := vl[k];
            if pm_poison(v) array_add(*vals, const_poison(vsty));
            else if pm_undef_value(v) array_add(*vals, const_undef(vsty));
            else array_add(*vals, const_null_value(vsty));
        }
        return const_vector_of(vals);
    }
    return cf_get_splat(type_vector(type_count(vtype(root)), scalar_type(b.sty), false), sce_all_ones_value(scalar_type(b.sty)));
}

Pbv_Action :: struct {
    te: Te_Id;
    non_constants: *[..] Value_Id;
    vec_ty: Type_Id;
    vf: s64;
    orig_sty: Type_Id;
    sty: Type_Id;
}

// finalize(ExtMask, SubVectors, SubVectorsMask, VF, Action)
bv_finalize :: (b: *Bv_Builder, ext_mask: [] s32, sub_vectors: [] [2] s64, sub_vectors_mask: [] s32, vf: s64 = 0, action: *Pbv_Action = null) -> Cost {
    b.is_finalized = true;
    if action {
        vec := b.in_vectors[0];
        if b.in_vectors.count == 2 b.cost = cost_add(b.cost, sce_create_shuffle(b, vec, b.in_vectors[1], b.common_mask));
        else b.cost = cost_add(b.cost, sce_create_shuffle(b, vec, Pu.{}, b.common_mask));
        vec = b.in_vectors[0];
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
        v := vec.v;
        pbv_run_action(b, action, *v, *b.common_mask);
        b.in_vectors[0] = pu_v(v);
    }
    if sub_vectors.count {
        vec := b.in_vectors[0];
        if b.in_vectors.count == 2 b.cost = cost_add(b.cost, sce_create_shuffle(b, vec, b.in_vectors[1], b.common_mask));
        else b.cost = cost_add(b.cost, sce_create_shuffle(b, vec, Pu.{}, b.common_mask));
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
        if sub_vectors_mask.count {
            svm := new_mask(b.common_mask.count);
            for sub_vectors_mask svm[it_index] = it;
            for i2, k: b.common_mask if i2 != PME svm[k] = i2 + cast(s32) b.common_mask.count;
            b.cost = cost_add(b.cost, slp_shuffle_cost(SK_PERMUTE_TWO_SRC, slp_widened_type(b.sty, cast(u64) b.common_mask.count), svm));
        }
        for sv: sub_vectors {
            e := cast(Te_Id) sv[0]; idx := sv[1];
            esty := vtype(slp.entries[e].scalars[0]);
            signed := true;
            found, bw := slp_min_bw_of(e);
            if found { esty = type_int(cast(u32) bw.bits); signed = bw.signed; }
            evf := cast(u64) te_vector_factor(e);
            if b.sty != esty {
                opc: Opcode = .TRUNC;
                if dl_type_size_bits(b.sty) > dl_type_size_bits(esty) opc = ifx signed then .SEXT else .ZEXT;
                b.cost = cost_add(b.cost, tti_cast_cost(slp.tti, opc, slp_widened_type(b.sty, evf), slp_widened_type(esty, evf), CCH_NORMAL, TCK_RECIP_THROUGHPUT));
            }
            b.cost = cost_add(b.cost, slp_shuffle_cost(SK_INSERT_SUBVECTOR, slp_widened_type(b.sty, cast(u64) b.common_mask.count), .[], TCK_RECIP_THROUGHPUT, idx,
                                                       slp_widened_type(b.sty, evf)));
            if b.common_mask.count for k: 0..cast(s64) evf - 1 b.common_mask[idx + k] = cast(s32) (idx + k);
        }
    }
    if ext_mask.count {
        if b.common_mask.count == 0 b.common_mask = mask_copy(ext_mask);
        else {
            nm := new_mask(ext_mask.count);
            for x, i: ext_mask if x != PME nm[i] = b.common_mask[x];
            b.common_mask = nm;
        }
    }
    if b.common_mask.count == 0 return b.cost;
    vl: [] Value_Id;
    if b.bv_engaged vl = b.bv_values;
    return cost_add(b.cost, sce_create_shuffle(b, b.in_vectors[0], ifx b.in_vectors.count == 2 then b.in_vectors[1] else Pu.{}, b.common_mask, vl));
}

// ---------------------------------------------------------------- processBuildVector

// the TryPackScalars lambda
pbv_try_pack_scalars :: (te: Te_Id, scalars: *[..] Value_Id, reuse_mask: *[..] s32, is_root_poison: bool, vf: s64, orig_sty: Type_Id) -> bool {
    e := *slp.entries[te];
    need_freeze := false;
    is_splat := is_root_poison && slp_is_splat(scalars.*) && (scalars.count > 2 || scalars.*[0] == scalars.*[scalars.count - 1]);
    while scalars.count < vf array_add(scalars, const_poison(orig_sty));
    undef_pos: [..] s64; undef_pos.allocator = temp;
    uniq_keys: [..] Value_Id; uniq_keys.allocator = temp; uniq_pos: [..] s64; uniq_pos.allocator = temp;
    num_non_consts := 0;
    single_pos := 0;
    for i: 0..scalars.count-1 {
        v := scalars.*[i];
        if pm_undef_value(v) {
            if !pm_poison(v) { reuse_mask.*[i] = cast(s32) i; array_add(*undef_pos, i); }
            continue;
        }
        if slp_is_constant(v) { reuse_mask.*[i] = cast(s32) i; continue; }
        num_non_consts += 1;
        single_pos = i;
        orig := v;
        scalars.*[i] = const_poison(orig_sty);
        if is_splat {
            scalars.*[0] = orig;
            reuse_mask.*[i] = 0;
        } else {
            p := -1;
            for uniq_keys if it == orig { p = uniq_pos[it_index]; break; }
            if p < 0 { array_add(*uniq_keys, orig); array_add(*uniq_pos, i); p = i; }
            scalars.*[p] = orig;
            reuse_mask.*[i] = cast(s32) p;
        }
    }
    if num_non_consts == 1 {
        if is_splat {
            for * reuse_mask.* it.* = PME;
            while reuse_mask.count < vf array_add(reuse_mask, PME);
            t := scalars.*[0]; scalars.*[0] = scalars.*[single_pos]; scalars.*[single_pos] = t;
            if undef_pos.count && undef_pos[0] == 0 scalars.*[0] = const_undef(orig_sty);
        }
        reuse_mask.*[single_pos] = cast(s32) single_pos;
    } else if undef_pos.count && is_splat {
        pos := -1;
        for v, k: scalars.* {
            if pm_undef_value(v) continue;
            ok := slp_is_vectorized(v) || is_guaranteed_not_to_be_poison(v, slp.ac);
            if !ok && e.user_tree_index.user != TE_NONE {
                u := ir.v_first_use[v];
                while u != NONE {
                    usr := ir.u_user[u];
                    if e.user_tree_index.edge != use_operand_no(u) && slp_has(slp.entries[e.user_tree_index.user].scalars, usr) { ok = true; break; }
                    u = ir.u_next[u];
                }
            }
            if ok { pos = k; break; }
        }
        if pos >= 0 {
            for i: undef_pos {
                reuse_mask.*[i] = cast(s32) pos;
                if i != pos scalars.*[i] = const_poison(orig_sty);
            }
        } else {
            for i: undef_pos {
                reuse_mask.*[i] = PME;
                if pm_undef_value(scalars.*[i]) scalars.*[i] = const_poison(orig_sty);
            }
            need_freeze = true;
        }
    }
    return need_freeze;
}

// the finalize Action lambda of processBuildVector
pbv_run_action :: (b: *Bv_Builder, a: *Pbv_Action, vec: *Value_Id, mask: *[..] s32) {
    nc := a.non_constants;
    is_splat := slp_is_splat(nc.*);
    bv_mask := new_mask(mask.count);
    if pbv_try_pack_scalars(a.te, nc, *bv_mask, false, a.vf, a.orig_sty) slp_fail("freeze of a broadcast with undefs in a gathered node");
    check_if_splat_is_profitable :: (a: *Pbv_Action, nc: [] Value_Id, mask: [] s32, bv_mask: [] s32, vec: Value_Id) -> bool {
        v: Value_Id = NONE; for nc if !pm_undef_value(it) { v = it; break; }
        if is_inst(v) && inst_op(v) == .EXTRACTELEMENT || slp_is_vectorized(v) return false;
        splat := tti_vector_instr_cost(slp.tti, .INSERTELEMENT, a.vec_ty, TCK_RECIP_THROUGHPUT, 0, const_poison(a.vec_ty), v);
        nm := mask_copy(mask);
        for i, idx: bv_mask if i != PME nm[idx] = cast(s32) mask.count;
        splat = cost_add(splat, slp_shuffle_cost(SK_PERMUTE_TWO_SRC, a.vec_ty, nm));
        first := 0; for mask if it != PME { first = it; break; }
        bv := tti_vector_instr_cost(slp.tti, .INSERTELEMENT, a.vec_ty, TCK_RECIP_THROUGHPUT, cast(u32) first, vec, v);
        cnt := 0; for bv_mask if it == PME cnt += 1;
        if cnt < bv_mask.count - 1 {
            nm2 := mask_copy(mask);
            for i, idx: bv_mask if i != PME nm2[idx] = i;
            bv = cost_add(bv, slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, a.vec_ty, nm2));
        }
        return splat <= bv;
    }
    if !is_splat || mask.count <= 2 || !check_if_splat_is_profitable(a, nc.*, mask.*, bv_mask, vec.*) {
        for i, idx: bv_mask if i != PME mask.*[idx] = i;
        vec.* = bv_gather(b, nc.*, mask.count, vec.*);
    } else {
        v: Value_Id = NONE; for nc.* if !pm_undef_value(it) { v = it; break; }
        values: [..] Value_Id; values.allocator = temp;
        for nc.* array_add(*values, const_poison(a.sty));
        values[0] = v;
        bvv := bv_gather(b, values, bv_mask.count);
        splat_mask := new_mask(bv_mask.count);
        for i, k: bv_mask splat_mask[k] = ifx i == PME then PME else 0;
        if !svm_is_identity(splat_mask, a.vf) {
            b.cost = cost_add(b.cost, sce_create_shuffle(b, pu_v(bvv), Pu.{}, splat_mask));
        }
        for i, idx: bv_mask if i != PME mask.*[idx] = cast(s32) (bv_mask.count + idx);
        b.cost = cost_add(b.cost, sce_create_shuffle(b, pu_v(vec.*), pu_v(bvv), mask.*));
        for i, idx: mask.* if i != PME mask.*[idx] = cast(s32) idx;
    }
}

// processBuildVector<ShuffleCostEstimator, InstructionCost>(E, ScalarTy, TTI, VectorizedVals, R, CheckedExtracts)
slp_build_vector_cost :: (te: Te_Id, sty: Type_Id, vectorized_vals: [] Value_Id, checked_extracts: *[..] Value_Id) -> Cost {
    b: Bv_Builder;
    bv_init_cost(*b, sty, vectorized_vals, checked_extracts);
    return slp_process_build_vector(te, sty, *b);
}

slp_process_build_vector :: (te: Te_Id, sty: Type_Id, b: *Bv_Builder) -> Cost {
    e := *slp.entries[te];
    vf := te_vector_factor(te);
    need_freeze := false;
    gathered := vl_copy(e.scalars);
    sub_vectors: [..] [2] s64; sub_vectors.allocator = temp;
    if !(e.state == TE_SPLIT_VECTORIZE && table_contains(*slp.transformed_to_gather_nodes, te)) {
        for cei: e.combined_entries_with_indices {
            n := te_vector_factor(cast(Te_Id) cei[0]);
            for k: 0..n-1 gathered[cei[1] + cast(u32) k] = const_poison(vtype(gathered[cei[1] + cast(u32) k]));
            array_add(*sub_vectors, .[cast(s64) cei[0], cast(s64) cei[1]]);
        }
    }
    reorder_mask := new_mask(); for e.reorder_indices array_add(*reorder_mask, cast(s32) it);
    if reorder_mask.count slp_reorder_scalars(*gathered, reorder_mask);
    sub_vectors_mask := slp_inverse_permutation(e.reorder_indices);
    if sub_vectors.count && sub_vectors_mask.count {
        for i: 0..gathered.count-1 if e.scalars[i] == gathered[reorder_mask[i]] sub_vectors_mask[reorder_mask[i]] = PME;
    } else array_reset_keeping_memory(*sub_vectors_mask);
    stored_gs := vl_copy(gathered);
    mask := new_mask();
    extract_mask := new_mask(gathered.count);
    extract_shuffles: [..] s64; extract_shuffles.allocator = temp;
    extract_vec_base: Value_Id = NONE;
    use_vec_base := false;
    gather_shuffles: [..] s64; gather_shuffles.allocator = temp;
    entries: [..] [..] Te_Id; entries.allocator = temp;
    orig_sty := vtype(gathered[0]);
    vec_ty := slp_widened_type(sty, cast(u64) gathered.count);
    num_parts := slp_number_of_parts(slp.tti, vec_ty, sty, cast(u64) gathered.count);
    all_undef := true; for gathered if !pm_undef_value(it) { all_undef = false; break; }
    if !all_undef {
        resized := false;
        extract_shuffles = slp_try_to_gather_extract_elements(gathered, *extract_mask, num_parts);
        if extract_shuffles.count {
            vb, uvb := sce_adjust_extracts(b, te, extract_mask, extract_shuffles, num_parts);
            use_vec_base = uvb;
            if vb != NONE {
                extract_vec_base = vb;
                vbt := vtype(vb);
                if type_kind(vbt) == .VECTOR && vf == cast(s64) type_count(vbt) && gathered.count != vf {
                    resized = true;
                    while gathered.count < vf array_add(*gathered, const_poison(orig_sty));
                    num_parts = slp_number_of_parts(slp.tti, slp_widened_type(orig_sty, cast(u64) vf), orig_sty, cast(u64) vf);
                }
            }
        }
        any_ld_vec := false;
        for v: e.scalars if is_inst(v) && inst_op(v) == .LOAD && slp_is_vectorized(v) { any_ld_vec = true; break; }
        any_ld := false; for v: e.scalars if is_inst(v) && inst_op(v) == .LOAD { any_ld = true; break; }
        all_vec := true; for v: e.scalars if !slp_is_vectorized(v) { all_vec = false; break; }
        if extract_shuffles.count || !te_has_state(te) || te_opcode(te) != .LOAD ||
           (((te_has_state(te) && te_opcode(te) == .LOAD) || any_ld) && any_ld_vec) ||
           (te_has_state(te) && is_alt_shuffle(e.s)) || all_vec || slp_is_splat(e.scalars) ||
           (!vl_equal(e.scalars, gathered) && gathered.count <= 2) {
            gather_shuffles = slp_is_gather_shuffled_entry(te, gathered, *mask, *entries, num_parts);
        }
        if gather_shuffles.count {
            if gather_shuffles.count == 1 && gather_shuffles[0] == SK_PERMUTE_SINGLE_SRC &&
               (te_is_same(entries[0][0], e.scalars) || te_is_same(te, slp.entries[entries[0][0]].scalars)) {
                array_resize(*mask, e.scalars.count);
                front := entries[0][0];
                fe := *slp.entries[front];
                if fe.reorder_indices.count == 0 && e.reorder_indices.count == 0 &&
                   ((fe.reuse_shuffle_indices.count == 0 && e.scalars.count == fe.scalars.count) || e.scalars.count == fe.reuse_shuffle_indices.count) {
                    for * mask it.* = cast(s32) it_index;
                } else {
                    for v, i: e.scalars {
                        if pm_poison(v) { mask[i] = PME; continue; }
                        mask[i] = cast(s32) te_find_lane_for_value(front, v);
                    }
                }
                sce_reset_for_same_node(b);
                if (te_is_same(te, fe.scalars) && fe.reuse_shuffle_indices.count == 0 && fe.reorder_indices.count == 0 && te_vector_factor(te) == te_vector_factor(front)) ||
                   (vl_equal(e.scalars, fe.scalars) && orders_equal(e.reorder_indices, fe.reorder_indices) && masks_equal(e.reuse_shuffle_indices, fe.reuse_shuffle_indices)) {
                    mask = new_mask(te_vector_factor(front));
                    for * mask it.* = cast(s32) it_index;
                    bv_add_te(b, front, mask);
                    return bv_finalize(b, .[], .[], .[]);
                }
                bv_add_te(b, front, mask);
                return bv_finalize(b, te_common_mask(te), .[], .[]);
            }
            if !resized {
                any := false;
                for tes: entries for tes if te_vector_factor(it) == vf { any = true; break; }
                if gathered.count != vf && any while gathered.count < vf array_add(*gathered, const_poison(orig_sty));
            }
            for i: 0..mask.count-1 if mask[i] != PME gathered[i] = const_poison(orig_sty);
        }
    }
    res: Cost = 0;
    if extract_shuffles.count || gather_shuffles.count {
        is_non_poisoned := true;
        is_used_in_expr := true;
        vec1: Value_Id = NONE;
        if extract_shuffles.count {
            vec2: Value_Id = NONE;
            for i: 0..extract_mask.count-1 if mask.count && mask[i] != PME extract_mask[i] = PME;
            if use_vec_base vec1 = extract_vec_base;
            else {
                for i: 0..extract_mask.count-1 {
                    if extract_mask[i] == PME continue;
                    if pm_undef_value(stored_gs[i]) continue;
                    vec_op := op(stored_gs[i], 0);
                    tes := slp_get_tree_entries(vec_op);
                    if tes.count && slp.entries[tes[0]].vectorized_value != NONE vec_op = slp.entries[tes[0]].vectorized_value;
                    if vec1 == NONE vec1 = vec_op;
                    else if vec1 != vec_op vec2 = vec_op;
                }
            }
            if vec2 != NONE {
                is_used_in_expr = false;
                is_non_poisoned &= is_guaranteed_not_to_be_poison(vec1, slp.ac) && is_guaranteed_not_to_be_poison(vec2, slp.ac);
                bv_add_v2(b, vec1, vec2, extract_mask);
            } else if vec1 != NONE {
                not_poisoned := is_guaranteed_not_to_be_poison(vec1, slp.ac);
                is_used_in_expr &= pbv_find_reused_splat(te, gathered, *extract_mask, cast(s64) type_count(vtype(vec1)), 0, extract_mask.count, not_poisoned);
                bv_add_v(b, vec1, extract_mask, true);
                is_non_poisoned &= not_poisoned;
            } else {
                is_used_in_expr = false;
                bv_add_v(b, const_poison(vec_ty), extract_mask, true);
            }
        }
        if gather_shuffles.count {
            slice := cast(s64) slp_part_num_elems(cast(u64) vf, num_parts);
            if mask.count == e.scalars.count
                slice = cast(s64) slp_part_num_elems(cast(u64) e.scalars.count, slp_number_of_parts(slp.tti, vec_ty, sty, cast(u64) e.scalars.count));
            vec_mask := new_mask(mask.count);
            for tes, i: entries {
                if tes.count == 0 continue;
                limit := cast(s64) slp_num_elems(cast(u64) mask.count, cast(u64) slice, cast(u64) i);
                for * vec_mask it.* = PME;
                for k: 0..limit-1 vec_mask[i * slice + k] = mask[i * slice + k];
                if tes.count == 1 {
                    vv := slp.entries[tes[0]].vectorized_value;
                    not_poisoned := ifx vv != NONE then is_guaranteed_not_to_be_poison(vv, slp.ac) else true;
                    is_used_in_expr &= pbv_find_reused_splat(te, gathered, *vec_mask, te_vector_factor(tes[0]), i, slice, not_poisoned);
                    bv_add_te(b, tes[0], vec_mask);
                    is_non_poisoned &= not_poisoned;
                } else {
                    is_used_in_expr = false;
                    bv_add_te2(b, tes[0], tes[1], vec_mask);
                    v0 := slp.entries[tes[0]].vectorized_value; v1 := slp.entries[tes[1]].vectorized_value;
                    if v0 != NONE && v1 != NONE is_non_poisoned &= is_guaranteed_not_to_be_poison(v0, slp.ac) && is_guaranteed_not_to_be_poison(v1, slp.ac);
                }
            }
        }
        non_constants := vl_copy(gathered);
        em_sz := extract_mask.count;
        m_sz := mask.count;
        is_single_shuffle := extract_shuffles.count == 0 || gather_shuffles.count == 0;
        all_single := true; for extract_shuffles if (ifx it == SK_NONE then SK_PERMUTE_TWO_SRC else it) != SK_PERMUTE_SINGLE_SRC { all_single = false; break; }
        none_ge := true; for extract_mask if it >= em_sz { none_ge = false; break; }
        g_single := true; for gather_shuffles if (ifx it == SK_NONE then SK_PERMUTE_TWO_SRC else it) != SK_PERMUTE_SINGLE_SRC { g_single = false; break; }
        g_none_ge := true; for mask if it >= m_sz { g_none_ge = false; break; }
        is_identity_shuffle := ((use_vec_base || all_single) && none_ge && svm_is_identity(extract_mask, em_sz)) ||
                               (gather_shuffles.count && g_single && g_none_ge && svm_is_identity(mask, m_sz));
        no_undef_np := true; for gathered if pm_undef_value(it) && !pm_poison(it) { no_undef_np = false; break; }
        any_const := false; for gathered if is_const(it) && !pm_undef_value(it) { any_const = true; break; }
        any_non_undef := false; for gathered if !pm_undef_value(it) { any_non_undef = true; break; }
        cnt_const := 0; for gathered if is_const(it) && !pm_poison(it) cnt_const += 1;
        enough := is_single_shuffle && (no_undef_np || any_const) &&
                  (!is_identity_shuffle || (gathered.count == 2 && any_non_undef) || cnt_const > 1);
        for i: 0..gathered.count-1 {
            if enough && is_const(gathered[i]) non_constants[i] = const_poison(orig_sty);
            else gathered[i] = const_poison(orig_sty);
        }
        all_poison := true; for gathered if !pm_poison(it) { all_poison = false; break; }
        if !all_poison {
            bv_mask := new_mask(gathered.count);
            if pbv_try_pack_scalars(te, *gathered, *bv_mask, true, vf, orig_sty) need_freeze = true;
            bv := bv_gather(b, gathered, bv_mask.count);
            bv_add_v(b, bv, bv_mask);
        }
        all_nc := true;
        for v: non_constants {
            if pm_poison(v) || (is_single_shuffle && ((is_identity_shuffle && is_non_poisoned) || is_used_in_expr) && pm_undef_value(v)) continue;
            all_nc = false; break;
        }
        if all_nc res = bv_finalize(b, e.reuse_shuffle_indices, sub_vectors, sub_vectors_mask);
        else {
            act: Pbv_Action;
            act.te = te; act.non_constants = *non_constants; act.vec_ty = vec_ty; act.vf = vf; act.orig_sty = orig_sty; act.sty = sty;
            res = bv_finalize(b, e.reuse_shuffle_indices, sub_vectors, sub_vectors_mask, e.scalars.count, *act);
        }
    } else if !slp_all_constant(gathered) {
        reuse_mask := new_mask(gathered.count);
        if pbv_try_pack_scalars(te, *gathered, *reuse_mask, true, vf, orig_sty) need_freeze = true;
        bv := bv_gather(b, gathered, reuse_mask.count);
        bv_add_v(b, bv, reuse_mask);
        res = bv_finalize(b, e.reuse_shuffle_indices, sub_vectors, sub_vectors_mask);
    } else {
        m := new_mask(gathered.count);
        for v, i: gathered if !pm_poison(v) m[i] = cast(s32) i;
        bv := bv_gather(b, gathered);
        bv_add_v(b, bv, m);
        res = bv_finalize(b, e.reuse_shuffle_indices, sub_vectors, sub_vectors_mask);
    }
    return res;   // createFreeze(Cost) is the identity for the cost estimator
}

// the FindReusedSplat lambda
pbv_find_reused_splat :: (te: Te_Id, gathered: [] Value_Id, mask: *[..] s32, input_vf: s64, i: s64, slice: s64, not_poisonous: bool) -> bool {
    e := *slp.entries[te];
    any_undef_np := false; for e.scalars if pm_undef_value(it) && !pm_poison(it) { any_undef_np = true; break; }
    if !slp_is_splat(e.scalars) || !any_undef_np return false;
    user := e.user_tree_index.user;
    edge := e.user_tree_index.edge;
    if slp.entries[user].operands.count != 2 return false;
    if !not_poisonous {
        found := TE_NONE;
        for k: user + 1..slp.entries.count-1 {
            o := *slp.entries[k];
            if o.user_tree_index.user == user && o.user_tree_index.edge != edge { found = cast(Te_Id) k; break; }
        }
        if found == TE_NONE return false;
        fe := *slp.entries[found];
        gs := vl_copy(fe.scalars);
        if fe.reorder_indices.count {
            rm := slp_inverse_permutation(fe.reorder_indices);
            slp_reorder_scalars(*gs, rm);
        }
        n := min(gathered.count, gs.count);
        for k: 0..n-1 {
            v0 := gathered[k]; v1 := gs[k];
            if !pm_undef_value(v0) || pm_poison(v0) || (pm_undef_value(v0) && !pm_poison(v0) && slp_has(e.scalars, v1)) continue;
            return false;
        }
    }
    ok, idx := svm_is_extract_subvector(mask.*, input_vf);
    n := cast(s64) slp_num_elems(cast(u64) mask.count, cast(u64) slice, cast(u64) i);
    if (mask.count < input_vf && ok && idx == 0) || (mask.count == input_vf && svm_is_identity(mask.*, mask.count)) {
        for k: 0..n-1 mask.*[i * slice + k] = cast(s32) k;
    } else {
        ival: s32 = 0; for mask.* if it != PME { ival = it; break; }
        for k: 0..n-1 mask.*[i * slice + k] = ival;
    }
    return true;
}
