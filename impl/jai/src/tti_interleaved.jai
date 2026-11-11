// TTI::getInterleavedMemoryOpCost: X86TTIImpl::getInterleavedMemoryOpCost (the SSE2-AVX2 tables),
// getInterleavedMemoryOpCostAVX512 and BasicTTIImplBase::getInterleavedMemoryOpCost (the generic fallback).
// Ported from llvm/lib/Target/X86/X86TargetTransformInfo.cpp and llvm/include/llvm/CodeGen/BasicTTIImpl.h
// (LLVM 23.1.5). The tables are XT_getInterleavedMemoryOpCost*_* in gen_x86_tti.jai (keyed by the factor).

// CostTableLookup on a factor-keyed table
x86_factor_table_lookup :: (tbl: [] XCost_Entry, factor: u32, m: u32) -> (bool, Cost) {
    for tbl if it.isd == factor && it.dst == m return true, it.c[0];
    return false, 0;
}

tti_interleaved_memory_op_cost :: (t: *Tti, opc: Opcode, vec_ty: Type_Id, factor: u32, indices: [] u32, align: u64, addrspace: u32,
                                   kind: s64, use_mask_for_cond: bool, use_mask_for_gaps: bool) -> Cost {
    if t.kind != .X86 return 1;
    return x86_interleaved_memory_op_cost(t, opc, vec_ty, factor, indices, align, addrspace, kind, use_mask_for_cond, use_mask_for_gaps);
}

x86_interleaved_memory_op_cost :: (t: *Tti, opc: Opcode, vec_ty: Type_Id, factor: u32, indices: [] u32, align: u64, addrspace: u32,
                                   kind: s64, use_mask_for_cond: bool, use_mask_for_gaps: bool) -> Cost {
    st := *t.xl;
    elt := type_elem(vec_ty);
    supported_on_avx512 :: (st: *X86_Lowering, elt: Type_Id) -> bool {
        k := type_kind(elt);
        if k == .FLOAT || k == .DOUBLE || k == .PTR return true;
        if k == .INT {
            b := type_int_width(elt);
            if b == 64 || b == 32 return true;
            if b == 16 || b == 8 return st_hasBWI(st);
            return false;
        }
        if k == .HALF return st_hasBWI(st);
        if k == .BFLOAT return xs_has(st, X86FLD_HasBF16);
        return false;
    }
    if st_hasAVX512(st) && supported_on_avx512(st, elt)
        return x86_interleaved_memory_op_cost_avx512(t, opc, vec_ty, factor, indices, align, addrspace, kind, use_mask_for_cond, use_mask_for_gaps);
    if use_mask_for_cond || use_mask_for_gaps
        return bt_interleaved_memory_op_cost(t, opc, vec_ty, factor, indices, align, addrspace, kind, use_mask_for_cond, use_mask_for_gaps);
    _, legal := bt_type_legalization_cost(st, vec_ty);
    if !mvt_is_vec(legal) return bt_interleaved_memory_op_cost(t, opc, vec_ty, factor, indices, align, addrspace, kind, false, false);
    vf := cast(u32) type_count(vec_ty) / factor;
    sty := elt;
    if type_kind(sty) != .INT sty = type_int(dl_type_size_bits(sty));
    mem_op_costs := x86_memory_op_cost(t, opc, vec_ty, align, addrspace, kind);
    vt := xvec(sty, vf);
    ety := x86_evt(st, vt);
    if !evt_is_simple(ety) return bt_interleaved_memory_op_cost(t, opc, vec_ty, factor, indices, align, addrspace, kind, false, false);
    m := ety.m;
    if opc == .LOAD {
        discounted :: (mem: Cost, n: s64, c: Cost, factor: u32) -> Cost {
            return cost_add(mem, (n * c + cast(s64) factor - 1) / cast(s64) factor);
        }
        if st_hasAVX2(st) { ok, c := x86_factor_table_lookup(XT_getInterleavedMemoryOpCost_AVX2InterleavedLoadTbl, factor, m); if ok return discounted(mem_op_costs, indices.count, c, factor); }
        if st_hasSSSE3(st) { ok, c := x86_factor_table_lookup(XT_getInterleavedMemoryOpCost_SSSE3InterleavedLoadTbl, factor, m); if ok return discounted(mem_op_costs, indices.count, c, factor); }
        if st_hasSSE2(st) { ok, c := x86_factor_table_lookup(XT_getInterleavedMemoryOpCost_SSE2InterleavedLoadTbl, factor, m); if ok return discounted(mem_op_costs, indices.count, c, factor); }
    } else {
        if st_hasAVX2(st) { ok, c := x86_factor_table_lookup(XT_getInterleavedMemoryOpCost_AVX2InterleavedStoreTbl, factor, m); if ok return cost_add(mem_op_costs, c); }
        if st_hasSSE2(st) { ok, c := x86_factor_table_lookup(XT_getInterleavedMemoryOpCost_SSE2InterleavedStoreTbl, factor, m); if ok return cost_add(mem_op_costs, c); }
    }
    return bt_interleaved_memory_op_cost(t, opc, vec_ty, factor, indices, align, addrspace, kind, use_mask_for_cond, use_mask_for_gaps);
}

// X86TTIImpl::getInterleavedMemoryOpCostAVX512
x86_interleaved_memory_op_cost_avx512 :: (t: *Tti, opc: Opcode, vec_ty: Type_Id, factor: u32, indices: [] u32, align: u64, addrspace: u32,
                                          kind: s64, use_mask_for_cond: bool, use_mask_for_gaps: bool) -> Cost {
    st := *t.xl;
    _, legal := bt_type_legalization_cost(st, vec_ty);
    vty_size := cast(s64) dl_type_store_size(vec_ty);
    legal_size := cast(s64) (mvt_bits(legal) + 7) / 8;
    num_mem_ops := (vty_size + legal_size - 1) / legal_size;
    elt := type_elem(vec_ty);
    single_ty := xvec(elt, cast(s64) mvt_n(legal));
    use_masked := use_mask_for_cond || use_mask_for_gaps;
    mem_op_cost: Cost;
    if use_masked {
        m: Mica;
        m.id = iidn(ifx opc == .LOAD then "llvm.masked.load" else "llvm.masked.store");
        m.data_ty = single_ty; m.align = align; m.addrspace = addrspace;
        mem_op_cost = x86_masked_memory_op_cost(t, *m, kind);
    } else mem_op_cost = x86_memory_op_cost(t, opc, single_ty, align, addrspace, kind);
    n := cast(u32) type_count(vec_ty);
    vf := n / factor;
    sevt := x86_evt(st, elt);   // TLI->getSimpleValueType(DL, scalar type)
    vt := mvt_vec(mvt_elt_code(sevt.m), vf);
    mask_cost: Cost = 0;
    if use_masked {
        dem := NewArray(cast(s64) n, bool,, allocator = temp);
        for idx: indices for e: 0..vf - 1 dem[idx + e * factor] = true;
        all := NewArray(cast(s64) n, bool,, allocator = temp);
        for * all it.* = true;
        i1 := type_int(1);
        mask_cost = x86_replication_shuffle_cost(t, i1, cast(s64) factor, cast(s64) vf, ifx use_mask_for_gaps then dem else all, kind);
        if use_mask_for_gaps mask_cost = cost_add(mask_cost, x86_arith_cost(t, .AND, xvec(i1, cast(s64) n), kind, OI_ANY, OI_ANY));
    }
    if opc == .LOAD {
        ok, c := x86_factor_table_lookup(XT_getInterleavedMemoryOpCostAVX512_AVX512InterleavedLoadTbl, factor, vt);
        if ok return cost_add(cost_add(mask_cost, cost_mul(num_mem_ops, mem_op_cost)), c);
        sk := ifx num_mem_ops > 1 then SK_PERMUTE_TWO_SRC else SK_PERMUTE_SINGLE_SRC;
        shuffle_cost := x86_shuffle_cost(t, sk, single_ty, single_ty, .[], kind, 0, NONE, .[], NONE);
        num_loads := ifx indices.count then cast(s64) indices.count else cast(s64) factor;
        result_ty := xvec(elt, cast(s64) (n / factor));
        rl, _ := bt_type_legalization_cost(st, result_ty);
        num_results := cost_mul(rl, num_loads);
        num_unfolded := ifx use_masked || num_results > 1 then num_mem_ops else num_mem_ops / 2;
        shuffles_per_result := max(cast(s64) 1, num_mem_ops - 1);
        num_moves: Cost = 0;
        if num_results > 1 && sk == SK_PERMUTE_TWO_SRC num_moves = num_results * shuffles_per_result / 2;
        return cost_add(cost_add(cost_add(cost_mul(cost_mul(num_results, shuffles_per_result), shuffle_cost), mask_cost),
                                 cost_mul(num_unfolded, mem_op_cost)), num_moves);
    }
    ok, c := x86_factor_table_lookup(XT_getInterleavedMemoryOpCostAVX512_AVX512InterleavedStoreTbl, factor, vt);
    if ok return cost_add(cost_add(mask_cost, cost_mul(num_mem_ops, mem_op_cost)), c);
    shuffle_cost := x86_shuffle_cost(t, SK_PERMUTE_TWO_SRC, single_ty, single_ty, .[], kind, 0, NONE, .[], NONE);
    shuffles_per_store := cast(s64) factor - 1;
    num_moves := num_mem_ops * shuffles_per_store / 2;
    return cost_add(cost_add(mask_cost, cost_mul(num_mem_ops, cost_add(mem_op_cost, cost_mul(shuffles_per_store, shuffle_cost)))), num_moves);
}

// BasicTTIImplBase::getInterleavedMemoryOpCost (thisT() = X86TTIImpl)
bt_interleaved_memory_op_cost :: (t: *Tti, opc: Opcode, vec_ty: Type_Id, factor: u32, indices: [] u32, align: u64, addrspace: u32,
                                  kind: s64, use_mask_for_cond: bool, use_mask_for_gaps: bool) -> Cost {
    if type_kind(vec_ty) == .SVECTOR return COST_INVALID;
    st := *t.xl;
    n := cast(u32) type_count(vec_ty);
    nsub := n / factor;
    elt := type_elem(vec_ty);
    sub_ty := xvec(elt, cast(s64) nsub);
    c: Cost;
    if use_mask_for_cond || use_mask_for_gaps {
        m: Mica;
        m.id = iidn(ifx opc == .LOAD then "llvm.masked.load" else "llvm.masked.store");
        m.data_ty = vec_ty; m.align = align; m.addrspace = addrspace;
        c = x86_mem_intrinsic_cost(t, *m, kind);
    } else c = x86_memory_op_cost(t, opc, vec_ty, align, addrspace, kind);
    _, lt := bt_type_legalization_cost(st, vec_ty);
    vsize := cast(u64) dl_type_store_size(vec_ty);
    ltsize := cast(u64) (mvt_bits(lt) + 7) / 8;
    if cost_valid(c) && vsize > ltsize {
        num_legal := (vsize + ltsize - 1) / ltsize;
        per_legal := (cast(u64) n + num_legal - 1) / num_legal;
        used := NewArray(cast(s64) num_legal, bool,, allocator = temp);
        for idx: indices for e: 0..nsub - 1 used[(idx + e * factor) / per_legal] = true;
        cnt: u64 = 0;
        for used if it cnt += 1;
        c = cast(Cost) ((cnt * cast(u64) c + num_legal - 1) / num_legal);
    }
    all_sub := NewArray(cast(s64) nsub, bool,, allocator = temp);
    for * all_sub it.* = true;
    dem := NewArray(cast(s64) n, bool,, allocator = temp);
    for idx: indices for e: 0..nsub - 1 dem[idx + e * factor] = true;
    if opc == .LOAD {
        ins_sub := x86_scalarization_overhead_dem(t, sub_ty, all_sub, true, false, kind);
        c = cost_add(c, cost_mul(cast(s64) indices.count, ins_sub));
        c = cost_add(c, x86_scalarization_overhead_dem(t, vec_ty, dem, false, true, kind));
    } else {
        ext_sub := x86_scalarization_overhead_dem(t, sub_ty, all_sub, false, true, kind);
        c = cost_add(c, cost_mul(ext_sub, cast(s64) indices.count));
        c = cost_add(c, x86_scalarization_overhead_dem(t, vec_ty, dem, true, false, kind));
    }
    if !use_mask_for_cond return c;
    i8 := type_int(8);
    all := NewArray(cast(s64) n, bool,, allocator = temp);
    for * all it.* = true;
    c = cost_add(c, x86_replication_shuffle_cost(t, i8, cast(s64) factor, cast(s64) nsub, ifx use_mask_for_gaps then dem else all, kind));
    if use_mask_for_gaps c = cost_add(c, x86_arith_cost(t, .AND, xvec(i8, cast(s64) n), kind, OI_ANY, OI_ANY));
    return c;
}
