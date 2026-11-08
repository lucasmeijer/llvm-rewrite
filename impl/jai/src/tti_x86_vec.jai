// X86 TTI vector costs, ported from llvm/lib/Target/X86/X86TargetTransformInfo.cpp (getShuffleCost,
// getVectorInstrCost, getScalarizationOverhead, getReplicationShuffleCost, the vector part of getMemoryOpCost) and
// the BasicTTIImplBase fallbacks they reach in llvm/include/llvm/CodeGen/BasicTTIImpl.h (improveShuffleKindFromMask,
// getShuffleCost, get*ShuffleOverhead, getScalarizationOverhead, getVectorInstrCost, getReplicationShuffleCost),
// plus processShuffleMasks (llvm/lib/Analysis/VectorUtils.cpp) and APIntOps::ScaleBitMask.
//
// Demanded-element sets are [] bool (one entry per vector element). Element indices use U32_NONE for "unknown"
// (LLVM's -1U).

U32_NONE : u32 : 0xFFFF_FFFF;

// TTI::SK_* -> the ISD_SK_* opcode the generated cost tables use (0: kinds that have no table rows)
sk_table_isd :: (sk: s64) -> u32 {
    if sk == {
        case SK_BROADCAST; return ISD_SK_Broadcast;
        case SK_REVERSE; return ISD_SK_Reverse;
        case SK_SELECT; return ISD_SK_Select;
        case SK_TRANSPOSE; return ISD_SK_Transpose;
        case SK_PERMUTE_TWO_SRC; return ISD_SK_PermuteTwoSrc;
        case SK_PERMUTE_SINGLE_SRC; return ISD_SK_PermuteSingleSrc;
        case SK_SPLICE; return ISD_SK_Splice;
    }
    return 0;
}

xvec :: (elt: Type_Id, n: s64) -> Type_Id { return type_vector(cast(u64) n, elt, false); }
xvec_n :: (t: Type_Id) -> s64 { return cast(s64) type_count(t); }

// APIntOps::ScaleBitMask(A, NewBitWidth, MatchAllBits)
scale_bit_mask :: (a: [] bool, new_width: s64, match_all := false) -> [] bool {
    r := NewArray(new_width, bool,, temp);
    old := a.count;
    if new_width == old { for a r[it_index] = it; return r; }
    if new_width > old {
        scale := new_width / old;
        for i: 0..new_width-1 r[i] = a[i / scale];
    } else {
        scale := old / new_width;
        for i: 0..new_width-1 {
            v := match_all;
            for j: 0..scale-1 {
                b := a[i * scale + j];
                if match_all v = v && b; else v = v || b;
            }
            r[i] = v;
        }
    }
    return r;
}
all_true :: (n: s64) -> [] bool { r := NewArray(n, bool,, temp); for * r it.* = true; return r; }

// BasicTTIImplBase::isSplatMask
bt_is_splat_mask :: (mask: [] s32, n: s64) -> (bool, s32) {
    compared := false;
    splat: s32 = -1;
    for mask {
        last := it_index == mask.count - 1;
        if it < 0 { if last && !compared return false, 0; continue; }
        if it >= n * 2 return false, 0;
        if splat == -1 { splat = it; if last return false, 0; continue; }
        compared = true;
        if splat != it return false, 0;
    }
    return true, splat;
}

// ShuffleVectorInst::isReplicationMask (static form)
svm_is_replication :: (mask: [] s32) -> (bool, s64, s64) {
    with_params :: (mask: [] s32, rf: s64, vf: s64) -> bool {
        for e: 0..vf-1 for k: 0..rf-1 { m := mask[e * rf + k]; if m != -1 && m != e return false; }
        return true;
    }
    has_poison := false;
    for mask if it == -1 has_poison = true;
    if !has_poison {
        rf := 0;
        while rf < mask.count && mask[rf] == 0 rf += 1;
        if rf == 0 || mask.count % rf != 0 return false, 0, 0;
        vf := mask.count / rf;
        return with_params(mask, rf, vf), rf, vf;
    }
    largest: s64 = -1;
    for mask { if it == -1 continue; if it < largest return false, 0, 0; largest = max(largest, it); }
    rf := mask.count;
    while rf >= 1 {
        if mask.count % rf == 0 && with_params(mask, rf, mask.count / rf) return true, rf, mask.count / rf;
        rf -= 1;
    }
    return false, 0, 0;
}
// the instance form: VF is the source element count
svm_is_replication_vf :: (mask: [] s32, vf: s64) -> (bool, s64) {
    if mask.count % vf != 0 return false, 0;
    rf := mask.count / vf;
    for e: 0..vf-1 for k: 0..rf-1 { m := mask[e * rf + k]; if m != -1 && m != e return false, 0; }
    return true, rf;
}

// ---------------------------------------------------------------- getVectorInstrCost

// BasicTTIImplBase::getVectorInstrCost = getRegUsageForType(Val->getScalarType())
bt_vector_instr_cost :: (t: *Tti, ty: Type_Id) -> Cost { return x86_reg_usage_for_type(*t.xl, scalar_type(ty)); }

// getVectorInstrCost(const Instruction &I, Val, CostKind, Index): Op0/Op1 from an insertelement
x86_vector_inst_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, index: u32, i: Value_Id) -> Cost {
    o0: Value_Id = NONE; o1: Value_Id = NONE;
    if i != NONE && inst_op(i) == .INSERTELEMENT { o0 = op(i, 0); o1 = op(i, 1); }
    return x86_vector_instr_cost(t, opc, ty, kind, index, o0, o1);
}

// X86TTIImpl::getVectorInstrCost(Opcode, Val, CostKind, Index, Op0, Op1)
x86_vector_instr_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, index_in: u32, op0: Value_Id, op1: Value_Id) -> Cost {
    st := *t.xl;
    if type_kind(ty) == .SVECTOR return COST_INVALID;
    sty := scalar_type(ty);
    move_cost: Cost = 0;
    index := index_in;
    is_ee := opc == .EXTRACTELEMENT; is_ie := opc == .INSERTELEMENT;
    if index == U32_NONE && (is_ee || is_ie) {
        va := dl_pref_align(ty); sa := dl_pref_align(sty);
        if is_ee return cost_add(x86_memory_op_cost(t, .STORE, ty, va, 0, kind), x86_memory_op_cost(t, .LOAD, sty, sa, 0, kind));
        return cost_add(cost_add(x86_memory_op_cost(t, .STORE, ty, va, 0, kind), x86_memory_op_cost(t, .STORE, sty, sa, 0, kind)),
                        x86_memory_op_cost(t, .LOAD, ty, va, 0, kind));
    }
    if index != U32_NONE && (is_ee || is_ie) {
        if is_ee && dl_type_size_bits(sty) == 1 && xvec_n(ty) > 1 && is_int_type(sty) return 1;
        ltc, ltm := bt_type_legalization_cost(st, ty);
        if !mvt_is_vec(ltm) return TCC_FREE;
        size_bits := mvt_bits(ltm);
        nelts := mvt_n(ltm);
        sub_n := nelts;
        index = index % nelts;
        if size_bits > 128 {
            nsub := size_bits / 128;
            sub_n = nelts / nsub;
            if sub_n <= index {
                move_cost += ifx is_ie then 2 else 1;
                index %= sub_n;
            }
        }
        ms := mvt_scalar(ltm);
        cheap :: (st: *X86_Lowering, ms: u32, index: u32, is_ie: bool) -> bool {
            return (ms == MVT_i16 && st_hasSSE2(st)) || (mvt_is_int(ms) && st_hasSSE41(st)) ||
                   (ms == MVT_f32 && st_hasSSE1(st) && index == 0 && is_ie) || (ms == MVT_f32 && st_hasSSE41(st) && is_ie);
        }
        if index == 0 {
            if is_fp_type(sty) && (!is_ie || op0 == NONE || is_undef_value(op0)) return move_cost;
            if is_ie && op0 != NONE && is_undef_value(op0) {
                if op1 != NONE && is_inst(op1) && inst_op(op1) == .LOAD return move_cost;
                if !cheap(st, ms, index, is_ie) {
                    if op1 != NONE && is_constant_kind(vkind(op1)) && is_int_type(vtype(op1)) return 2 + move_cost;
                    return 1 + move_cost;
                }
            }
            if is_int_type(sty) && is_ee return 1 + move_cost;
        }
        isd: u32 = ifx is_ee then ISD_EXTRACT_VECTOR_ELT else ISD_INSERT_VECTOR_ELT;
        if st_useSLMArithCosts(st) {
            for XT_getVectorInstrCost_SLMCostTbl if it.isd == isd && it.dst == ms return cost_add(it.c[0], move_cost);
        }
        if cheap(st, ms, index, is_ie) return 1 + move_cost;
        shuffle: Cost = 1;
        if is_ie {
            sub_ty := ty;
            vt := x86_evt(st, ty);
            if !evt_is_simple(evt_elt(vt)) || evt_elt(vt).m != ms || evt_bits(vt) >= 128 sub_ty = xvec(sty, sub_n);
            shuffle = x86_shuffle_cost(t, SK_PERMUTE_TWO_SRC, sub_ty, sub_ty, .[], kind, 0, sub_ty, .[], NONE);
        }
        int_or_fp: Cost = ifx is_fp_type(sty) then 0 else 1;
        return cost_add(cost_add(shuffle, int_or_fp), move_cost);
    }
    return cost_add(bt_vector_instr_cost(t, ty), move_cost);
}

// ---------------------------------------------------------------- getScalarizationOverhead

// BasicTTIImplBase::getScalarizationOverhead(Ty, DemandedElts, Insert, Extract, CostKind, ForPoisonSrc, VL)
bt_scalarization_overhead_dem :: (t: *Tti, ty: Type_Id, dem: [] bool, insert: bool, extract: bool, kind: s64, vl: [] Value_Id = .[]) -> Cost {
    if type_kind(ty) == .SVECTOR return COST_INVALID;
    c: Cost = 0;
    for k: 0..xvec_n(ty)-1 {
        if !dem[k] continue;
        if insert c = cost_add(c, x86_vector_instr_cost(t, .INSERTELEMENT, ty, kind, cast(u32) k, NONE, ifx vl.count then vl[k] else NONE));
        if extract c = cost_add(c, x86_vector_instr_cost(t, .EXTRACTELEMENT, ty, kind, cast(u32) k, NONE, NONE));
    }
    return c;
}

// X86TTIImpl::getScalarizationOverhead(Ty, DemandedElts, Insert, Extract, CostKind, ForPoisonSrc, VL)
x86_scalarization_overhead_dem :: (t: *Tti, ty: Type_Id, dem: [] bool, insert: bool, extract: bool, kind: s64, for_poison_src := true, vl: [] Value_Id = .[]) -> Cost {
    st := *t.xl;
    ltc, ltm := bt_type_legalization_cost(st, ty);
    ms := mvt_scalar(ltm);
    legal_bits := mvt_bits(ltm);
    c: Cost = 0;
    LANE :: 128;
    nlegal := ltc;
    elt := type_elem(ty);
    if insert && !for_poison_src {
        zero := const_null_value(ty);
        for k: 0..dem.count-1 {
            if !dem[k] continue;
            c = cost_add(c, x86_vector_instr_cost(t, .INSERTELEMENT, ty, kind, cast(u32) k, zero, ifx vl.count then vl[k] else NONE));
        }
        return c;
    }
    if insert {
        if (ms == MVT_i16 && st_hasSSE2(st)) || (mvt_is_int(ms) && st_hasSSE41(st)) || (ms == MVT_f32 && st_hasSSE41(st)) {
            if legal_bits <= LANE {
                c = cost_add(c, bt_scalarization_overhead_dem(t, ty, dem, insert, false, kind));
            } else {
                nlanes := cast(s64) (legal_bits / LANE);
                ntotal := nlanes * nlegal;
                nlegal_elts := cast(s64) mvt_n(ltm) * nlegal;
                per_lane := nlegal_elts / ntotal;
                wid := NewArray(nlegal_elts, bool,, temp);
                for dem wid[it_index] = it;
                lane_ty := xvec(elt, per_lane);
                for i: 0..ntotal-1 {
                    lm := array_view(wid, i * per_lane, per_lane);
                    any := false; all := true;
                    for lm { any |= it; all &= it; }
                    if !any continue;
                    if !all c = cost_add(c, x86_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, ty, ty, .[], kind, i * per_lane, lane_ty, .[], NONE));
                    c = cost_add(c, bt_scalarization_overhead_dem(t, lane_ty, lm, insert, false, kind));
                }
                affected := scale_bit_mask(wid, ntotal);
                fully := scale_bit_mask(affected, nlegal, true);
                for lv: 0..nlegal-1 for lane: 0..nlanes-1 {
                    i := nlanes * lv + lane;
                    if !affected[i] || (lane == 0 && fully[lv]) continue;
                    c = cost_add(c, x86_shuffle_cost(t, SK_INSERT_SUBVECTOR, ty, ty, .[], kind, i * per_lane, lane_ty, .[], NONE));
                }
            }
        } else if mvt_is_vec(ltm) {
            if is_int_type(elt) { for dem if it c += 1; }
            ne := cast(s64) mvt_n(ltm);
            p2: s64 = 1; while p2 < xvec_n(ty) p2 *= 2;
            c = cost_add(c, cost_mul(min(ne, p2) - 1, ltc));
        }
    }
    if extract {
        if !insert && dl_type_size_bits(elt) == 1 && is_int_type(elt) && !st_hasAVX512(st) {
            ne := xvec_n(ty);
            mx: s64 = ifx st_hasAVX2(st) then 32 else 16;
            return (ne + mx - 1) / mx;
        }
        if mvt_is_vec(ltm) {
            nlegal_elts := cast(s64) mvt_n(ltm) * nlegal;
            if legal_bits > LANE {
                nlanes := cast(s64) (legal_bits / LANE);
                ntotal := nlanes * nlegal;
                per_lane := nlegal_elts / ntotal;
                wid := NewArray(nlegal_elts, bool,, temp);
                for dem wid[it_index] = it;
                lane_ty := xvec(elt, per_lane);
                for i: 0..ntotal-1 {
                    lm := array_view(wid, i * per_lane, per_lane);
                    any := false; for lm any |= it;
                    if !any continue;
                    c = cost_add(c, x86_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, ty, ty, .[], kind, i * per_lane, lane_ty, .[], NONE));
                    c = cost_add(c, bt_scalarization_overhead_dem(t, lane_ty, lm, false, extract, kind));
                }
                return c;
            }
        }
        c = cost_add(c, bt_scalarization_overhead_dem(t, ty, dem, false, extract, kind));
    }
    return c;
}

// getScalarizationOverhead(Ty, Insert, Extract, CostKind): every element demanded
bt_scalarization_overhead :: (t: *Tti, ty: Type_Id, insert: bool, extract: bool, kind: s64) -> Cost {
    if type_kind(ty) == .SVECTOR return COST_INVALID;
    return x86_scalarization_overhead_dem(t, ty, all_true(xvec_n(ty)), insert, extract, kind);
}
// getOperandsScalarizationOverhead(Tys, CostKind)
bt_operands_scalarization_overhead :: (t: *Tti, tys: [] Type_Id, kind: s64) -> Cost {
    c: Cost = 0;
    for ty: tys {
        s := scalar_type(ty);
        if !is_int_type(s) && !is_fp_type(s) && !is_ptr_type(s) continue;
        if is_vector_type(ty) c = cost_add(c, bt_scalarization_overhead(t, ty, false, true, kind));
    }
    return c;
}
// getScalarizationOverhead(RetTy, Args, Tys, CostKind)
bt_scalarization_overhead_args :: (t: *Tti, ty: Type_Id, args: [] Value_Id, tys: [] Type_Id, kind: s64) -> Cost {
    c := bt_scalarization_overhead(t, ty, true, false, kind);
    if args.count {
        // filterConstantAndDuplicatedOperands
        seen: [..] Value_Id; seen.allocator = temp;
        ft: [..] Type_Id; ft.allocator = temp;
        for a: args {
            if is_constant_kind(vkind(a)) continue;
            dup := false; for seen if it == a dup = true;
            if dup continue;
            array_add(*seen, a);
            array_add(*ft, tys[it_index]);
        }
        c = cost_add(c, bt_operands_scalarization_overhead(t, ft, kind));
    } else c = cost_add(c, bt_scalarization_overhead(t, ty, false, true, kind));
    return c;
}

// ---------------------------------------------------------------- getShuffleCost

// BasicTTIImplBase::improveShuffleKindFromMask: (kind, index, sub type)
bt_improve_shuffle_kind :: (sk: s64, mask: [] s32, src: Type_Id, index_in: s64, sub_in: Type_Id) -> (s64, s64, Type_Id) {
    index := index_in; sub := sub_in;
    if mask.count == 0 return sk, index, sub;
    nd := mask.count;
    ns := xvec_n(src);
    if sk == SK_PERMUTE_SINGLE_SRC {
        if svm_is_reverse(mask, ns) return SK_REVERSE, index, sub;
        if svm_is_zero_elt_splat(mask, ns) return SK_BROADCAST, index, sub;
        ok, si := bt_is_splat_mask(mask, ns);
        if ok return SK_BROADCAST, si, sub;
        ok2, ei := svm_is_extract_subvector(mask, ns);
        if ok2 && ei + nd <= ns return SK_EXTRACT_SUBVECTOR, ei, xvec(type_elem(src), nd);
        return sk, index, sub;
    }
    if sk == SK_PERMUTE_TWO_SRC {
        all_lhs := true;
        for mask if it >= ns all_lhs = false;
        if all_lhs { k2, i2, s2 := bt_improve_shuffle_kind(SK_PERMUTE_SINGLE_SRC, mask, src, index, sub); return k2, i2, s2; }
        if nd > 2 {
            ok, nsub, ii := svm_is_insert_subvector(mask, ns);
            if ok {
                if ii + nsub > ns return sk, ii, sub;
                return SK_INSERT_SUBVECTOR, ii, xvec(type_elem(src), nsub);
            }
        }
        if svm_is_select(mask, ns) return SK_SELECT, index, sub;
        if svm_is_transpose(mask, ns) return SK_TRANSPOSE, index, sub;
        ok3, spl := svm_is_splice(mask, ns);
        if ok3 return SK_SPLICE, spl, sub;
        return sk, index, sub;
    }
    return sk, index, sub;
}

// BasicTTIImplBase::getShuffleCost
bt_shuffle_cost :: (t: *Tti, sk_in: s64, dst: Type_Id, src: Type_Id, mask: [] s32, kind: s64, index_in: s64, sub_in: Type_Id) -> Cost {
    sk, index, sub := bt_improve_shuffle_kind(sk_in, mask, src, index_in, sub_in);
    fixed := type_kind(src) == .VECTOR;
    if sk == {
        case SK_BROADCAST;
            if !fixed return COST_INVALID;
            c := x86_vector_instr_cost(t, .EXTRACTELEMENT, src, kind, 0, NONE, NONE);
            for k: 0..xvec_n(src)-1 c = cost_add(c, x86_vector_instr_cost(t, .INSERTELEMENT, src, kind, cast(u32) k, NONE, NONE));
            return c;
        case SK_EXTRACT_SUBVECTOR;
            c: Cost = 0;
            for k: 0..xvec_n(sub)-1 {
                c = cost_add(c, x86_vector_instr_cost(t, .EXTRACTELEMENT, src, kind, cast(u32) (k + index), NONE, NONE));
                c = cost_add(c, x86_vector_instr_cost(t, .INSERTELEMENT, sub, kind, cast(u32) k, NONE, NONE));
            }
            return c;
        case SK_INSERT_SUBVECTOR;
            c: Cost = 0;
            for k: 0..xvec_n(sub)-1 {
                c = cost_add(c, x86_vector_instr_cost(t, .EXTRACTELEMENT, sub, kind, cast(u32) k, NONE, NONE));
                c = cost_add(c, x86_vector_instr_cost(t, .INSERTELEMENT, dst, kind, cast(u32) (k + index), NONE, NONE));
            }
            return c;
    }
    if !fixed return COST_INVALID;
    c: Cost = 0;
    for k: 0..xvec_n(src)-1 {
        c = cost_add(c, x86_vector_instr_cost(t, .INSERTELEMENT, src, kind, cast(u32) k, NONE, NONE));
        c = cost_add(c, x86_vector_instr_cost(t, .EXTRACTELEMENT, src, kind, cast(u32) k, NONE, NONE));
    }
    return c;
}

// processShuffleMasks(Mask, NumOfSrcRegs, NumOfDestRegs, NumOfUsedRegs, NoInput, SingleInput, ManyInputs) with the
// actions of X86TTIImpl::getShuffleCost's split-register estimate folded in
x86_split_shuffle_cost :: (t: *Tti, mask: [] s32, nsrc: s64, ndst: s64, single_ty: Type_Id, kind: s64) -> Cost {
    sz := mask.count;
    sz_dest := sz / ndst;
    sz_src := sz / nsrc;
    res: [..] [..] [..] s32; res.allocator = temp;
    for i: 0..ndst-1 {
        regs: [..] [..] s32; regs.allocator = temp;
        for k: 0..2*nsrc-1 { e: [..] s32; e.allocator = temp; array_add(*regs, e); }
        for k: 0..sz_dest-1 {
            idx := i * sz_dest + k;
            if idx == sz break;
            m := mask[idx];
            if m >= 2 * sz || m == -1 continue;
            mi := m % sz;
            sri := mi / sz_src + (ifx m >= sz then nsrc else 0);
            if regs[sri].count == 0 { array_resize(*regs[sri], sz_dest); for * regs[sri] it.* = -1; }
            regs[sri][k] = cast(s32) (mi % sz_src);
        }
        array_add(*res, regs);
    }
    cost: Cost = 0;
    prev_src: s64 = 0;
    prev_mask: [] s32;
    single :: (t: *Tti, rm: [] s32, src_reg: s64, dst_reg: s64, single_ty: Type_Id, kind: s64, cost: *Cost, prev_src: *s64, prev_mask: *[] s32) {
        if !svm_is_identity(rm, rm.count) {
            same := prev_mask.count == rm.count;
            if same for rm if it != prev_mask.*[it_index] { same = false; break; }
            if prev_mask.count == 0 || prev_src.* != src_reg || !same
                cost.* = cost_add(cost.*, x86_shuffle_cost(t, SK_PERMUTE_SINGLE_SRC, single_ty, single_ty, rm, kind, 0, NONE, .[], NONE));
            else cost.* = cost_add(cost.*, TCC_BASIC);
            return;
        }
        prev_src.* = src_reg;
        prev_mask.* = rm;
    }
    many :: (t: *Tti, rm: [] s32, single_ty: Type_Id, kind: s64, cost: *Cost) {
        cost.* = cost_add(cost.*, x86_shuffle_cost(t, SK_PERMUTE_TWO_SRC, single_ty, single_ty, rm, kind, 0, NONE, .[], NONE));
    }
    for i: 0..ndst-1 {
        dest := res[i];
        nused := 0;
        for dest if it.count nused += 1;
        if nused == 0 continue;
        if nused == 1 {
            for dest if it.count { single(t, it, it_index, i, single_ty, kind, *cost, *prev_src, *prev_mask); break; }
            continue;
        }
        combine :: (first: [] s32, second: [] s32) {
            vf := first.count;
            for k: 0..vf-1 if second[k] != -1 first[k] = second[k] + cast(s32) vf;
        }
        normalize :: (m: [] s32) { for * m if it.* != -1 it.* = cast(s32) it_index; }
        second_idx: s64;
        while true {
            first_idx: s64 = -1;
            second_idx = -1;
            first_mask: [] s32; second_mask: [] s32;
            for k: 0..2*nsrc-1 {
                if dest[k].count == 0 continue;
                if first_idx == second_idx { first_idx = k; first_mask = dest[k]; continue; }
                second_idx = k;
                second_mask = dest[k];
                combine(first_mask, second_mask);
                many(t, first_mask, single_ty, kind, *cost);
                normalize(first_mask);
                dest[k].count = 0;
                second_mask = first_mask;
                second_idx = first_idx;
            }
            if first_idx != second_idx && second_idx >= 0 {
                combine(second_mask, first_mask);
                many(t, second_mask, single_ty, kind, *cost);
                dest[first_idx].count = 0;
                normalize(second_mask);
            }
            if second_idx < 0 break;
        }
    }
    return cost;
}

// X86TTIImpl::getShuffleCost
x86_shuffle_cost :: (t: *Tti, sk_in: s64, dst: Type_Id, src: Type_Id, mask: [] s32, kind: s64, index_in: s64, sub_in: Type_Id, args: [] Value_Id, cxt: Value_Id) -> Cost {
    st := *t.xl;
    ltc, ltm := bt_type_legalization_cost(st, src);
    sk, index, sub := bt_improve_shuffle_kind(sk_in, mask, src, index_in, sub_in);
    if args.count {
        all_const := true;
        for args if !is_constant_kind(vkind(it)) all_const = false;
        if all_const return TCC_FREE;
    }
    ns := xvec_n(src);
    elt := type_elem(src);
    if sk == SK_PERMUTE_TWO_SRC && mask.count == 2 * ns && svm_is_identity(mask, mask.count) {
        d := xvec(elt, 2 * ns);
        return x86_shuffle_cost(t, SK_INSERT_SUBVECTOR, d, d, mask, kind, mask.count / 2, src, .[], NONE);
    }
    if sk == SK_TRANSPOSE && ltm != MVT_v4f64 && ltm != MVT_v4i64 sk = SK_PERMUTE_TWO_SRC;
    if sk == SK_BROADCAST {
        ltc = 1;
        if args.count {
            a0 := args[0];
            is_load := is_inst(a0) && inst_op(a0) == .LOAD;
            foldable := false;
            if is_load && type_kind(dst) == .VECTOR && cast(s64) num_uses(a0) == xvec_n(dst) {
                foldable = true;
                u := ir.v_first_use[a0];
                while u != NONE {
                    usr := ir.u_user[u];
                    ok := false;
                    if is_inst(usr) && inst_op(usr) == .INSERTELEMENT && op(usr, 1) == a0 ok = true;
                    else if is_vector_type(vtype(usr)) ok = false;
                    else if is_inst(usr) && (is_terminator(inst_op(usr)) || inst_op(usr) == .PHI || inst_op(usr) == .ATOMICRMW || inst_op(usr) == .CMPXCHG) ok = false;
                    else if is_inst(usr) && is_call_base(usr) ok = call_memory_effects(usr) == 0 && !may_have_side_effects(usr);
                    else ok = true;
                    if !ok { foldable = false; break; }
                    u = ir.u_next[u];
                }
            }
            if ((is_load && num_uses(a0) == 1) || foldable) && (st_hasAVX2(st) || (st_hasAVX(st) && mvt_scalar_bits(ltm) >= 32)) return TCC_FREE;
        }
    }
    in_lane := false; single_elt := false;
    psize := ic_primitive_size_bits(src);
    if psize > 0 && psize % 128 == 0 && ic_primitive_size_bits(elt) == mvt_scalar_bits(ltm) && mask.count == ns {
        nlanes := cast(s64) (psize / 128);
        per := mask.count / nlanes;
        if mask.count % nlanes == 0 {
            in_lane = true;
            for mask if it != -1 && ((it % mask.count) / per) != (it_index / per) { in_lane = false; break; }
            np := 0; for mask if it == -1 np += 1;
            single_elt = mask.count - 1 == np;
        }
    }
    if mvt_is_vec(ltm) && mvt_scalar(ltm) == MVT_bf16 ltm = mvt_vec(MVT_f16, mvt_n(ltm));
    if sk == SK_EXTRACT_SUBVECTOR && mvt_is_vec(ltm) {
        ne := cast(s64) mvt_n(ltm);
        if index % ne == 0 return TCC_FREE;
        subc, subm := bt_type_legalization_cost(st, sub);
        if mvt_is_vec(subm) {
            nse := cast(s64) mvt_n(subm);
            if index % nse == 0 && ne % nse == 0 return subc;
            orig := xvec_n(sub);
            if nse > orig && index % orig == 0 && nse % orig == 0 && mvt_scalar(ltm) == mvt_scalar(subm) && mvt_scalar_bits(ltm) == ic_primitive_size_bits(elt) {
                vt := xvec(elt, ne);
                subt := xvec(elt, nse);
                ei := ((index % ne) / nse) * nse;
                ec := x86_shuffle_cost(t, SK_EXTRACT_SUBVECTOR, vt, vt, .[], kind, ei, subt, .[], NONE);
                if ic_primitive_size_bits(sub) >= 32 || st_hasSSSE3(st) return cost_add(ec, 1);
                return cost_add(ec, 2);
            }
        }
        sk = SK_PERMUTE_SINGLE_SRC;
    }
    if sk == SK_INSERT_SUBVECTOR && mvt_is_vec(ltm) {
        dc, dm := bt_type_legalization_cost(st, dst);
        ne := cast(s64) mvt_n(dm);
        subc, subm := bt_type_legalization_cost(st, sub);
        if mvt_is_vec(subm) {
            nse := cast(s64) mvt_n(subm);
            matching := ne == nse && xvec_n(sub) % nse == 0;
            if index % nse == 0 && ne % nse == 0 return ifx matching then TCC_FREE else subc;
        }
        if ltc == 1 && ltm == MVT_v4f32 && subc == 1 && subm == MVT_f32 && (index == 0 || st_hasSSE41(st)) return 1;
        sk = ifx index == 0 && ltc == 1 then SK_SELECT else SK_PERMUTE_TWO_SRC;
    }
    vt := x86_evt(st, src);
    isd := sk_table_isd(sk);
    lookup :: (tbl: [] XCost_Entry, isd: u32, m: u32, kind: s64) -> (bool, Cost) {
        if isd == 0 return false, 0;
        for tbl if it.isd == isd && it.dst == m { if it.c[kind] < 0 return false, 0; return true, it.c[kind]; }
        return false, 0;
    }
    if evt_is_simple(vt) && mvt_is_vec(vt.m) && mvt_bits(vt.m) < 128 && !st_hasSSSE3(st) {
        if st_hasSSE2(st) { ok, c := lookup(XT_getShuffleCost_SSE2SubVectorShuffleTbl, isd, vt.m, kind); if ok return cost_mul(ltc, c); }
    }
    if ltc != 1 {
        lv := ltm;
        if mvt_is_vec(lv) && mvt_scalar_bits(lv) == ic_primitive_size_bits(elt) && cast(s64) mvt_n(lv) < ns {
            vsize := cast(s64) dl_type_store_size(src);
            lsize := cast(s64) (mvt_bits(lv) + 7) / 8;
            nsrcs := (vsize + lsize - 1) / lsize;
            ndests := ltc;
            single_ty := xvec(elt, mvt_n(lv));
            if mask.count && cost_valid(ndests) {
                ndc, _ := bt_type_legalization_cost(st, xvec(elt, mask.count));
                e := ndc;
                nvf := cast(s64) mvt_n(lv) * max(nsrcs, e);
                nregs := nvf / cast(s64) mvt_n(lv);
                nm := NewArray(nvf, s32,, temp);
                for * nm it.* = -1;
                for mask nm[it_index] = it;
                return x86_split_shuffle_cost(t, nm, nregs, nregs, single_ty, kind);
            }
            nshuf := cost_mul(nsrcs - 1, ndests);
            return cost_mul(nshuf, x86_shuffle_cost(t, SK_PERMUTE_TWO_SRC, single_ty, single_ty, .[], kind, 0, NONE, .[], NONE));
        }
        return bt_shuffle_cost(t, sk, dst, src, mask, kind, index, sub);
    }
    if ltc == 1 && in_lane && single_elt return TCC_BASIC;
    m := ltm;
    Row :: struct { cond: bool; tbl: [] XCost_Entry; }
    rows := Row.[
        .{st_hasVBMI(st), XT_getShuffleCost_AVX512VBMIShuffleTbl},
        .{st_hasBWI(st), XT_getShuffleCost_AVX512BWShuffleTbl},
        .{in_lane && st_hasAVX512(st), XT_getShuffleCost_AVX512InLaneShuffleTbl},
        .{st_hasAVX512(st), XT_getShuffleCost_AVX512ShuffleTbl},
        .{in_lane && st_hasAVX2(st), XT_getShuffleCost_AVX2InLaneShuffleTbl},
        .{st_hasAVX2(st), XT_getShuffleCost_AVX2ShuffleTbl},
        .{st_hasXOP(st), XT_getShuffleCost_XOPShuffleTbl},
        .{in_lane && st_hasAVX(st), XT_getShuffleCost_AVX1InLaneShuffleTbl},
        .{st_hasAVX(st), XT_getShuffleCost_AVX1ShuffleTbl},
        .{st_hasSSE41(st), XT_getShuffleCost_SSE41ShuffleTbl},
        .{st_hasSSSE3(st), XT_getShuffleCost_SSSE3ShuffleTbl},
    ];
    for rows if it.cond { ok, c := lookup(it.tbl, isd, m, kind); if ok return cost_mul(ltc, c); }
    if st_hasSSE2(st) {
        is_load := false;
        for args if is_inst(it) && inst_op(it) == .LOAD is_load = true;
        if st_hasSSE3(st) && is_load && isd != 0 {
            // a CostTblEntry: one cost for every kind
            for XT_getShuffleCost_SSE3BroadcastLoadTbl if it.isd == isd && it.dst == m return cost_mul(ltc, it.c[0]);
        }
        ok, c := lookup(XT_getShuffleCost_SSE2ShuffleTbl, isd, m, kind);
        if ok return cost_mul(ltc, c);
    }
    if st_hasSSE1(st) {
        if ltc == 1 && ltm == MVT_v4f32 && mask.count == 4 {
            shufps :: (x: s32, y: s32) -> bool { return x < 0 || y < 0 || (x & 4) == (y & 4); }
            if shufps(mask[0], mask[1]) && shufps(mask[2], mask[3]) return 1;
        }
        ok, c := lookup(XT_getShuffleCost_SSE1ShuffleTbl, isd, m, kind);
        if ok return cost_mul(ltc, c);
    }
    return bt_shuffle_cost(t, sk, dst, src, mask, kind, index, sub);
}

// ---------------------------------------------------------------- getReplicationShuffleCost

// BasicTTIImplBase::getReplicationShuffleCost
bt_replication_shuffle_cost :: (t: *Tti, elt: Type_Id, rf: s64, vf: s64, dem_dst: [] bool, kind: s64) -> Cost {
    src_vt := xvec(elt, vf);
    rep_vt := xvec(elt, vf * rf);
    dem_src := scale_bit_mask(dem_dst, vf);
    c := x86_scalarization_overhead_dem(t, src_vt, dem_src, false, true, kind);
    return cost_add(c, x86_scalarization_overhead_dem(t, rep_vt, dem_dst, true, false, kind));
}

// X86TTIImpl::getReplicationShuffleCost
x86_replication_shuffle_cost :: (t: *Tti, elt_in: Type_Id, rf: s64, vf: s64, dem_dst: [] bool, kind: s64) -> Cost {
    st := *t.xl;
    bits := cast(u32) dl_type_size_bits(elt_in);
    elt := type_int(bits);
    if !st_hasAVX512(st) return bt_replication_shuffle_cost(t, elt, rf, vf, dem_dst, kind);
    prom := bits;
    if bits == {
        case 32; case 64;
        case 16; if !st_hasBWI(st) prom = 32;
        case 8; if !st_hasVBMI(st) prom = 32;
        case 1;
            if st_hasBWI(st) prom = ifx st_hasVBMI(st) then cast(u32) 8 else 16;
            else prom = 32;
        case; return bt_replication_shuffle_cost(t, elt, rf, vf, dem_dst, kind);
    }
    pelt := type_int(prom);
    src_vt := xvec(elt, vf);
    psrc_vt := xvec(pelt, vf);
    nd := vf * rf;
    pdst_vt := xvec(pelt, nd);
    dst_vt := xvec(elt, nd);
    _, ls := bt_type_legalization_cost(st, src_vt);
    _, lps := bt_type_legalization_cost(st, psrc_vt);
    _, lpd := bt_type_legalization_cost(st, pdst_vt);
    _, ld := bt_type_legalization_cost(st, dst_vt);
    if !mvt_is_vec(ls) || !mvt_is_vec(lps) || !mvt_is_vec(lpd) || !mvt_is_vec(ld) return bt_replication_shuffle_cost(t, elt, rf, vf, dem_dst, kind);
    if prom != bits {
        pc := x86_cast_cost(t, .SEXT, psrc_vt, src_vt, CCH_NONE, kind);
        pc = cost_add(pc, x86_cast_cost(t, .TRUNC, dst_vt, pdst_vt, CCH_NONE, kind));
        return cost_add(pc, x86_replication_shuffle_cost(t, pelt, rf, vf, dem_dst, kind));
    }
    per := cast(s64) mvt_n(ld);
    ndv := (nd + per - 1) / per;
    single := xvec(elt, per);
    wid := NewArray(ndv * per, bool,, temp);
    for dem_dst wid[it_index] = it;
    dv := scale_bit_mask(wid, ndv);
    nddem := 0; for dv if it nddem += 1;
    sc := x86_shuffle_cost(t, SK_PERMUTE_SINGLE_SRC, single, single, .[], kind, 0, NONE, .[], NONE);
    return cost_mul(nddem, sc);
}

// ---------------------------------------------------------------- getMemoryOpCost (vectors)

// the vector part of X86TTIImpl::getMemoryOpCost (RecipThroughput, `c` = the constant-store load cost so far)
x86_vector_memory_op_cost :: (t: *Tti, opc: Opcode, src: Type_Id, align_in: u64, addrspace: u32, kind: s64, opinfo: Op_Info, i: Value_Id, c_in: Cost, ltm: u32) -> Cost {
    st := *t.xl;
    c := c_in;
    align := align_in;
    is_load := opc == .LOAD;
    elt := type_elem(src);
    ebits := cast(s64) dl_type_size_bits(elt);
    nsrc := xvec_n(src);
    remaining := nsrc;
    max_bytes := (cast(s64) mvt_bits(ltm) + 7) / 8;
    XMM :: 128;
    if XMM % ebits != 0 return bt_memory_op_cost(t, opc, src, align, addrspace, kind, opinfo, i);
    per_xmm := XMM / ebits;
    xmm_ty := xvec(elt, per_xmm);
    cur_bytes := max_bytes;
    sub_left := 0;
    while remaining > 0 {
        if (8 * cur_bytes) % ebits != 0 return bt_memory_op_cost(t, opc, src, align, addrspace, kind, opinfo, i);
        per_op := (8 * cur_bytes) / ebits;
        cur_ty := ifx per_op > per_xmm then xvec(elt, per_op) else xmm_ty;
        coal_ty := ifx per_op == 1 then cur_ty else xvec(type_int(cast(u32) (ebits * per_op)), xvec_n(cur_ty) / per_op);
        while remaining > 0 {
            if remaining < per_op && (!is_load || cast(s64) align < cur_bytes) && cur_bytes != 1 break;
            if cur_bytes == 32 && xs_has(st, X86FLD_IsUnalignedMem32Slow) c += 2;
            else if cur_bytes < 4 c += 2;
            else c += 1;
            if is_load && oi_is_uniform(opinfo) return c;
            done := nsrc - remaining;
            is0 := done % cast(s64) mvt_n(ltm) == 0;
            if sub_left == 0 {
                sub_left += xvec_n(cur_ty);
                if !is0 c = cost_add(c, x86_shuffle_cost(t, ifx is_load then SK_INSERT_SUBVECTOR else SK_EXTRACT_SUBVECTOR, src, src, .[], kind, done, cur_ty, .[], NONE));
            }
            if cur_bytes <= 4 && !is0 {
                in_xmm := done % per_xmm;
                ci := in_xmm / per_op;
                dem := NewArray(xvec_n(coal_ty), bool,, temp);
                dem[ci] = true;
                c = cost_add(c, x86_scalarization_overhead_dem(t, coal_ty, dem, is_load, !is_load, kind));
            }
            sub_left -= per_op;
            remaining -= per_op;
            // commonAlignment(Alignment, CurrOpSizeBytes)
            v := align | cast(u64) cur_bytes;
            align = v & (~v + 1);
        }
        cur_bytes /= 2;
    }
    return c;
}
