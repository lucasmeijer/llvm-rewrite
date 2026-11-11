// The legacy LoopVectorizationCostModel costs: getInstructionCost and its helpers (memory, scalarization, calls,
// div/rem speculation), the costs setCostBasedWideningDecision records, collectInstsToScalarize /
// computePredInstDiscount, expectedCost (the scalar loop) and getPredBlockCostDivisor.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp (LLVM 23.1.5).

// LLVM 23's InstructionCost is fixed point with CostGranularity 4 (divisions by block-frequency divisors give
// fractions such as 8.5). The loop vectorizer computes in that domain: an `Lc` is 4 * the cost, and COST_INVALID
// (and above) is still the invalid state. TTI answers are converted with lcv; lc_value is getValue().
Lc :: Cost;
LC_GRANULARITY :: 4;
LV_COST_MAX : Lc : COST_INVALID - 1;    // InstructionCost::getMax()
lcv :: (c: Cost) -> Lc {
    if !cost_valid(c) return COST_INVALID;
    if c > LV_COST_MAX / LC_GRANULARITY return LV_COST_MAX;
    if c < -LV_COST_MAX / LC_GRANULARITY return -LV_COST_MAX;
    return c * LC_GRANULARITY;
}
lc_value :: (c: Lc) -> s64 { assert(cost_valid(c)); return c / LC_GRANULARITY; }
// saturating like InstructionCost's operators; invalid propagates
lc_add :: (a: Lc, b: Lc) -> Lc {
    if !cost_valid(a) || !cost_valid(b) return COST_INVALID;
    r := a + b;
    if r > LV_COST_MAX return LV_COST_MAX;
    if r < -LV_COST_MAX return -LV_COST_MAX;
    return r;
}
// InstructionCost * CostType
lc_mul :: (a: Lc, n: s64) -> Lc {
    if !cost_valid(a) return COST_INVALID;
    if a != 0 && n != 0 && (a > LV_COST_MAX / n || a < -LV_COST_MAX / n || (n < 0 && a > LV_COST_MAX / -n)) {
        if (a > 0) == (n > 0) return LV_COST_MAX;
        return -LV_COST_MAX;
    }
    return a * n;
}
// InstructionCost / CostType (operator/= on the raw value)
lc_div :: (a: Lc, n: u64) -> Lc {
    if !cost_valid(a) return COST_INVALID;
    return a / cast(s64) n;
}
lc_sub :: (a: Lc, b: Lc) -> Lc {
    if !cost_valid(a) || !cost_valid(b) return COST_INVALID;
    return lc_add(a, -b);
}
// InstructionCost::print
lc_str :: (c: Lc) -> string {
    if !cost_valid(c) return "Invalid";
    a := ifx c < 0 then -c else c;
    whole := a / LC_GRANULARITY;
    rem := ((a % LC_GRANULARITY) * 100) / LC_GRANULARITY;
    while rem % 10 == 0 && rem rem /= 10;
    sign := ifx c < 0 then "-" else "";
    if rem return tprint("%1%.%", sign, whole, rem);
    return tprint("%1%", sign, whole);
}

lv_debug_enabled :: () -> bool {
    p := vp_getenv("JAI_LV_DEBUG");
    return p != null && p[0] != 0 && p[0] != #char "0";
}
lv_dbg :: (fmt: string, args: ..Any) {
    if !lv_debug_enabled() return;
    s := tprint(fmt, ..args);
    write_string_stderr(s);
}
write_string_stderr :: (s: string) {
    libc_write :: (fd: s32, buf: *u8, n: u64) -> s64 #foreign libc_for_errno "write";
    libc_write(2, s.data, cast(u64) s.count);
}
lv_ec_str :: (vf: Ec) -> string { if vf.scalable return tprint("vscale x %", vf.n); return tprint("%", vf.n); }

// ---------------------------------------------------------------- TTI queries (in the Lc domain)

lt_arith_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, o1 := OI_ANY, o2 := OI_ANY, args: [] Value_Id = .[], cxt: Value_Id = NONE) -> Lc {
    return lcv(tti_arith_cost(t, opc, ty, kind, o1, o2, args, cxt));
}
lt_cast_cost :: (t: *Tti, opc: Opcode, dst: Type_Id, src: Type_Id, cch: u8, kind: s64, i: Value_Id = NONE) -> Lc {
    return lcv(tti_cast_cost(t, opc, dst, src, cch, kind, i));
}
lt_cf_cost :: (t: *Tti, opc: Opcode, kind: s64) -> Lc { return lcv(tti_cf_cost(t, opc, kind)); }
lt_cmp_sel_cost :: (t: *Tti, opc: Opcode, val_ty: Type_Id, cond_ty: Type_Id, pred: u8, kind: s64, o1 := OI_ANY, o2 := OI_ANY, i: Value_Id = NONE) -> Lc {
    return lcv(tti_cmp_sel_cost(t, opc, val_ty, cond_ty, pred, kind, o1, o2, i));
}
lt_memory_op_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, align: u64, addrspace: u32, kind: s64, opinfo := OI_ANY, i: Value_Id = NONE) -> Lc {
    return lcv(tti_memory_op_cost(t, opc, ty, align, addrspace, kind, opinfo, i));
}
lt_insert_extract_value_cost :: (t: *Tti, opc: Opcode, kind: s64) -> Lc { return lcv(tti_insert_extract_value_cost(t, opc, kind)); }
lt_vector_instr_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, index: u32) -> Lc { return lcv(tti_vector_instr_cost(t, opc, ty, kind, index)); }
lt_instruction_cost :: (t: *Tti, i: Value_Id, kind: s64) -> Lc { return lcv(tti_instruction_cost(t, i, kind)); }
lt_intrinsic_cost :: (t: *Tti, a: *Ica, kind: s64) -> Lc { return lcv(tti_intrinsic_cost(t, a, kind)); }
lt_arithmetic_reduction_cost :: (t: *Tti, opc: Opcode, ty: Type_Id, has_fmf: bool, fmf: u32, kind: s64) -> Lc {
    return lcv(tti_arithmetic_reduction_cost(t, opc, ty, has_fmf, fmf, kind));
}
lt_min_max_reduction_cost :: (t: *Tti, id: Intrinsic_Id, ty: Type_Id, fmf: u32, kind: s64) -> Lc {
    return lcv(tti_min_max_reduction_cost(t, id, ty, fmf, kind));
}
// TTI::getAddressComputationCost(PtrTy, SE, Ptr, CostKind); has_se = false passes a null SE
lv_tti_address_computation_cost :: (t: *Tti, ptr_ty: Type_Id, has_se: bool, ptr_scev: Scev_Id) -> Lc {
    if t.kind != .X86 return 0;
    if is_vector_type(ptr_ty) && has_se && !st_hasAVX2(*t.xl) {
        if ptr_scev == SCEV_NULL || !sc_is_addrec(ptr_scev) return lcv(10);
        if !sc_is_const(sc_step_recurrence(ptr_scev)) return lcv(1);
    }
    return 0;
}
// TTI::getMemIntrinsicInstrCost
lv_tti_mem_intrinsic_cost :: (t: *Tti, name: string, data_ty: Type_Id, ptr: Value_Id, variable_mask: bool, align: u64, addrspace: u32, kind: s64, i: Value_Id = NONE) -> Lc {
    if t.kind != .X86 return lcv(1);
    m: Mica;
    m.id = iidn(name); m.data_ty = data_ty; m.ptr = ptr; m.variable_mask = variable_mask; m.align = align; m.addrspace = addrspace; m.inst = i;
    return lcv(x86_mem_intrinsic_cost(t, *m, kind));
}
// TTI::getScalarizationOverhead(Ty, all ones, Insert, Extract, CostKind)
lv_tti_scalarization_overhead_all :: (t: *Tti, ty: Type_Id, insert: bool, extract: bool, kind: s64) -> Lc {
    if type_kind(ty) != .VECTOR { if t.kind == .X86 && type_kind(ty) == .SVECTOR return COST_INVALID; return 0; }
    n := type_count(ty);
    dem := NewArray(cast(s64) n, bool,, allocator = temp);
    for * dem it.* = true;
    return lcv(tti_scalarization_overhead(t, ty, dem, insert, extract, kind));
}
// TTI::getOperandsScalarizationOverhead
lv_tti_operands_scalarization_overhead :: (t: *Tti, tys: [] Type_Id, kind: s64) -> Lc {
    if t.kind != .X86 return 0;
    return lcv(bt_operands_scalarization_overhead(t, tys, kind));
}
// TTI::getIndexedVectorInstrCostFromEnd
lv_tti_vector_instr_cost_from_end :: (t: *Tti, opc: Opcode, ty: Type_Id, kind: s64, index: u32) -> Lc {
    if type_kind(ty) == .SVECTOR return lcv(tti_vector_instr_cost(t, opc, ty, kind, U32_NONE));
    return lcv(tti_vector_instr_cost(t, opc, ty, kind, cast(u32) type_count(ty) - 1 - index));
}
lv_tti_shuffle :: (t: *Tti, sk: s64, ty: Type_Id, kind: s64, index: s64) -> Lc {
    return lcv(tti_shuffle_cost(t, sk, ty, ty, .[], kind, index, NONE, .[], NONE));
}
// TTI::getCallInstrCost (BasicTTIImplBase: 10; the base implementation: 1)
lv_tti_call_instr_cost :: (t: *Tti) -> Lc { return lcv(tti_call_instr_cost(t)); }
// TTI::getNumberOfParts
lv_tti_number_of_parts :: (t: *Tti, ty: Type_Id) -> u64 { return tti_number_of_parts(t, ty); }
// TTI::isLegalMaskedScatter
lv_tti_is_legal_masked_scatter :: (t: *Tti, ty: Type_Id, align: u64) -> bool {
    if t.kind != .X86 return false;
    return x86_is_legal_masked_scatter(*t.xl, ty);
}
// -force-target-instruction-cost
lv_forced_cost :: () -> Lc { return lcv(lv_opts.force_target_instruction_cost.v); }

// toVectorizedTy: vectors of the scalar (struct-typed values fail loudly)
lv_to_vectorized_ty :: (t: Type_Id, vf: Ec) -> Type_Id { return lv_to_vector_ty(t, vf); }
// canVectorizeTy (int, fp, pointer element types and literal structs of them)
lv_can_vectorize_ty :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .INT || is_fp_type(t) || k == .PTR return true;
    if k == .STRUCT vp_unported("struct-typed values in canVectorizeTy");
    return false;
}
// maybeVectorizeType
lv_maybe_vectorize_type :: (t: Type_Id, vf: Ec) -> Type_Id {
    if ec_is_scalar(vf) || !lv_can_vectorize_ty(t) return t;
    return lv_to_vectorized_ty(t, vf);
}

// ---------------------------------------------------------------- cost-model state queries

lv_cm_bfi :: (cm: *Lv_Cm) -> *Bfi {
    if !cm.bfi cm.bfi = get_bfi(cm.f);
    return cm.bfi;
}
lv_cm_widening_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Cost {
    found, d := table_find(*cm.decisions, lv_dec_key(i, vf));
    assert(found, "The cost is not calculated");
    return d.cost;
}
lv_cm_is_forced_scalar :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    if ec_is_scalar(vf) return false;
    st := lv_cm_vf_state(cm, vf);
    return st != null && array_find(st.forced_scalars, i);
}
lv_cm_scalarize_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Cost {
    st := lv_cm_vf_state(cm, vf);
    for st.insts_to_scalarize if it == i return st.insts_to_scalarize_cost[it_index];
    return 0;
}
lv_cm_min_bw :: (cm: *Lv_Cm, i: Value_Id) -> (bool, u64) {
    if cm.min_bws == null || i == NONE return false, 0;
    found, b := table_find(cm.min_bws, i);
    return found, b;
}
// canTruncateToMinimalBitwidth
lv_cm_can_truncate_to_minimal_bitwidth :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    if i == NONE || !is_inst(i) return false;
    found, bw := lv_cm_min_bw(cm, i);
    if inst_op(i) == .TRUNC && found && cast(u64) type_bits(scalar_type(vtype(i))) < bw return false;
    return ec_is_vector(vf) && found && !lv_cm_is_profitable_to_scalarize(cm, i, vf) && !lv_cm_is_scalar_after_vectorization(cm, i, vf);
}
// getPredBlockCostDivisor
lv_cm_pred_block_cost_divisor :: (cm: *Lv_Cm, bb: Value_Id) -> u64 {
    if cm.cost_kind == TCK_CODE_SIZE return 1;
    if !lvl_block_needs_predication(cm.lvl, bb) return 1;
    bfi := lv_cm_bfi(cm);
    hf := bfi_get_block_freq(bfi, li_header(cm.li, cm.l));
    bf := bfi_get_block_freq(bfi, bb);
    if bf == 0 vp_unported("a zero block frequency in getPredBlockCostDivisor");
    d := cast(float64) hf / cast(float64) bf;
    // std::round (d is positive), then the conversion to uint64_t
    if d + 0.5 >= 18446744073709551616.0 vp_unported("a block-frequency cost divisor out of range");
    return cast(u64) (d + 0.5);
}
// useEmulatedMaskMemRefHack
lv_cm_use_emulated_mask_mem_ref_hack :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    assert(lv_cm_is_predicated_inst(cm, i), "Expecting a scalar emulated instruction");
    return inst_op(i) == .LOAD || (inst_op(i) == .STORE && cm.num_pred_stores > lv_opts.num_stores_to_predicate);
}
// needsExtract
lv_cm_needs_extract :: (cm: *Lv_Cm, v: Value_Id, vf: Ec) -> bool {
    if ec_is_scalar(vf) || !is_inst(v) || !li_contains_inst(cm.li, cm.l, v) || lv_cm_widening_decision(cm, v, vf) == .SCALARIZE return false;
    st := lv_cm_vf_state(cm, vf);
    return st == null || !st.scalars_done || !lv_cm_is_scalar_after_vectorization(cm, v, vf);
}
// filterExtractingOperands
lv_cm_filter_extracting_operands :: (cm: *Lv_Cm, ops: [] Value_Id, vf: Ec) -> [..] Value_Id {
    res: [..] Value_Id; res.allocator = temp;
    seen: [..] Value_Id; seen.allocator = temp;
    for o: ops {
        if is_const(o) continue;
        if array_find(seen, o) continue;
        array_add(*seen, o);
        if !lv_cm_needs_extract(cm, o, vf) continue;
        array_add(*res, o);
    }
    return res;
}
lv_inst_operands :: (i: Value_Id, call_args_only: bool) -> [] Value_Id {
    n := ifx call_args_only then call_arg_count(i) else nops(i);
    out := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 out[k] = op(i, cast(u32) k);
    return out;
}

// LoopVectorizationCostModel::getScalarizationOverhead
lv_cm_scalarization_overhead :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Cost {
    if vf.scalable return COST_INVALID;
    if ec_is_scalar(vf) return 0;
    t := cm.tti; kind := cm.cost_kind;
    c: Cost = 0;
    ret_ty := lv_to_vectorized_ty(vtype(i), vf);
    o := inst_op(i);
    if type_kind(ret_ty) != .VOID   // (!isa<LoadInst> || !supportsEfficientVectorElementLoadStore): false for X86, base
        c = lc_add(c, lv_tti_scalarization_overhead_all(t, ret_ty, true, false, kind));
    if o == .LOAD && !lv_tti_prefers_vectorized_addressing(t) return c;
    ops := lv_inst_operands(i, o == .CALL);
    tys: [..] Type_Id; tys.allocator = temp;
    for v: lv_cm_filter_extracting_operands(cm, ops, vf) array_add(*tys, lv_maybe_vectorize_type(vtype(v), vf));
    return lc_add(c, lv_tti_operands_scalarization_overhead(t, tys, kind));
}

// getAddressAccessSCEV (the IR version)
lv_address_access_scev :: (cm: *Lv_Cm, ptr: Value_Id) -> Scev_Id {
    a := pse_get_scev(cm.pse, ptr);
    if lv_is_address_scev_for_cost(a, cm.l) return a;
    return SCEV_NULL;
}
// vputils::isAddressSCEVForCost
lv_is_address_scev_for_cost :: (a: Scev_Id, l: Loop_Id) -> bool {
    is_affine_ar :: (s: Scev_Id) -> bool { return sc_is_addrec(s) && sc_is_affine(s); }
    if sc_kind(a) == .ADD {
        for k: 0..cast(s64) sc_nops(a) - 1 {
            o := sc_op(a, cast(u32) k);
            if sc_is_loop_invariant(o, l) continue;
            if sc_kind(o) == .SEXT && is_affine_ar(sc_op(o, 0)) continue;
            if is_affine_ar(o) continue;
            return false;
        }
        return true;
    }
    return sc_is_loop_invariant(a, l) || is_affine_ar(a);
}

// getMemInstScalarizationCost
lv_cm_mem_inst_scalarization_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Cost {
    if vf.scalable return COST_INVALID;
    t := cm.tti; kind := cm.cost_kind;
    val_ty := load_store_type(i);
    ptr := load_store_pointer_operand(i);
    as := ptr_addrspace(vtype(ptr));
    ptr_ty := lv_to_vector_ty(vtype(ptr), vf);
    ptr_scev := lv_address_access_scev(cm, ptr);
    n := cast(s64) vf.n;
    c := lc_mul(lv_tti_address_computation_cost(t, ptr_ty, true, ptr_scev), n);
    c = lc_add(c, lc_mul(lt_memory_op_cost(t, inst_op(i), scalar_type(val_ty), load_store_align(i), as, kind, tti_operand_info(op(i, 0))), n));
    c = lc_add(c, lv_cm_scalarization_overhead(cm, i, vf));
    if lv_cm_is_predicated_inst(cm, i) {
        c = lc_div(c, lv_cm_pred_block_cost_divisor(cm, inst_block(i)));
        c = lc_add(c, lv_tti_scalarization_overhead_all(t, type_vector(vf.n, type_int(1), false), false, true, kind));
        c = lc_add(c, lt_cf_cost(t, .CONDBR, kind));
        if lv_cm_use_emulated_mask_mem_ref_hack(cm, i, vf) c = lcv(3000000);
    }
    return c;
}

// getConsecutiveMemOpCost
lv_cm_consecutive_mem_op_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec, w: Lv_Widening) -> Cost {
    t := cm.tti; kind := cm.cost_kind;
    vty := lv_to_vector_ty(load_store_type(i), vf);
    as := ptr_addrspace(vtype(load_store_pointer_operand(i)));
    align := load_store_align(i);
    c: Cost = 0;
    if lv_cm_is_mask_required(cm, i) {
        name := ifx inst_op(i) == .LOAD then "llvm.masked.load" else "llvm.masked.store";
        c = lc_add(c, lv_tti_mem_intrinsic_cost(t, name, vty, NONE, true, align, as, kind));
    } else {
        c = lc_add(c, lt_memory_op_cost(t, inst_op(i), vty, align, as, kind, tti_operand_info(op(i, 0)), i));
    }
    if w == .WIDEN_REVERSE c = lc_add(c, lv_tti_shuffle(t, SK_REVERSE, vty, kind, 0));
    return c;
}

// getUniformMemOpCost
lv_cm_uniform_mem_op_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Cost {
    t := cm.tti; kind := cm.cost_kind;
    val_ty := load_store_type(i);
    ptr_ty := vtype(load_store_pointer_operand(i));
    vty := lv_to_vector_ty(val_ty, vf);
    align := load_store_align(i);
    as := ptr_addrspace(ptr_ty);
    if inst_op(i) == .LOAD {
        return lc_add(lc_add(lv_tti_address_computation_cost(t, ptr_ty, false, SCEV_NULL),
                             lt_memory_op_cost(t, .LOAD, val_ty, align, as, kind)),
                      lv_tti_shuffle(t, SK_BROADCAST, vty, kind, 0));
    }
    inv_val := lvl_is_invariant(cm.lvl, op(i, 0));
    c := lc_add(lv_tti_address_computation_cost(t, ptr_ty, false, SCEV_NULL), lt_memory_op_cost(t, .STORE, val_ty, align, as, kind));
    if !inv_val c = lc_add(c, lv_tti_vector_instr_cost_from_end(t, .EXTRACTELEMENT, vty, kind, 0));
    return c;
}

// getGatherScatterCost
lv_cm_gather_scatter_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Cost {
    t := cm.tti; kind := cm.cost_kind;
    vty := lv_to_vector_ty(load_store_type(i), vf);
    align := load_store_align(i);
    ptr := load_store_pointer_operand(i);
    ptr_ty := vtype(ptr);
    if !lv_cm_is_uniform(cm, ptr, vf) ptr_ty = lv_to_vector_ty(ptr_ty, vf);
    name := ifx inst_op(i) == .LOAD then "llvm.masked.gather" else "llvm.masked.scatter";
    return lc_add(lv_tti_address_computation_cost(t, ptr_ty, false, SCEV_NULL),
                  lv_tti_mem_intrinsic_cost(t, name, vty, ptr, lv_cm_is_mask_required(cm, i), align, 0, kind, i));
}

// getMemoryInstructionCost
lv_cm_memory_instruction_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Cost {
    if ec_is_scalar(vf) {
        t := cm.tti; kind := cm.cost_kind;
        ptr_ty := vtype(load_store_pointer_operand(i));
        return lc_add(lv_tti_address_computation_cost(t, ptr_ty, false, SCEV_NULL),
                      lt_memory_op_cost(t, inst_op(i), load_store_type(i), load_store_align(i), ptr_addrspace(ptr_ty), kind,
                                         tti_operand_info(op(i, 0)), i));
    }
    return lv_cm_widening_cost(cm, i, vf);
}

// getDivRemSpeculationCost: (scalarization, masked intrinsic)
lv_cm_div_rem_speculation_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> (Cost, Cost) {
    t := cm.tti; kind := cm.cost_kind;
    sc := COST_INVALID;
    if !vf.scalable {
        n := cast(s64) vf.n;
        sc = lc_mul(lt_cf_cost(t, .PHI, kind), n);
        sc = lc_add(sc, lc_mul(lt_arith_cost(t, inst_op(i), vtype(i), kind), n));
        sc = lc_add(sc, lv_cm_scalarization_overhead(cm, i, vf));
        sc = lc_div(sc, lv_cm_pred_block_cost_divisor(cm, inst_block(i)));
    }
    vec_ty := lv_to_vector_ty(vtype(i), vf);
    mask_ty := lv_to_vector_ty(type_int(1), vf);
    name: string;
    if inst_op(i) == {
        case .UDIV; name = "llvm.masked.udiv";
        case .SDIV; name = "llvm.masked.sdiv";
        case .UREM; name = "llvm.masked.urem";
        case; name = "llvm.masked.srem";
    }
    id := iidn(name);
    if id == NOT_INTRINSIC vp_unported(tprint("the intrinsic %", name));
    a := ica_types(id, vec_ty, .[vec_ty, vec_ty, mask_ty]);
    mc := lt_intrinsic_cost(t, *a, kind);
    return sc, mc;
}
// isDivRemScalarWithPredication
lv_cm_is_div_rem_scalar_with_predication :: (sc: Cost, mc: Cost) -> bool {
    if lv_opts.force_masked_divrem.set return lv_opts.force_masked_divrem.v == 0;
    return sc < mc;
}

// getVectorIntrinsicCost
lv_cm_vector_intrinsic_cost :: (cm: *Lv_Cm, ci: Value_Id, vf: Ec) -> Cost {
    id := get_vector_intrinsic_id_for_call(ci);
    assert(id != NOT_INTRINSIC, "Expected intrinsic call!");
    a: Ica;
    a.id = id;
    a.ret = lv_maybe_vectorize_type(vtype(ci), vf);
    if is_fp_math_inst(ci) a.fmf = inst_fmf(ci);
    n := call_arg_count(ci);
    args := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 args[k] = op(ci, cast(u32) k);
    fty := inst(ci).ty2;
    // FunctionType params: sub 0 is the return type
    np := cast(s64) type_nsub(fty) - 1;
    tys := NewArray(np, Type_Id,, allocator = temp);
    for k: 0..np - 1 tys[k] = lv_maybe_vectorize_type(type_sub(fty, cast(u32) (k + 1)), vf);
    a.args = args; a.tys = tys;
    if call_iid(ci) != NOT_INTRINSIC a.inst = ci;
    a.scalar_cost = COST_INVALID;
    return lt_intrinsic_cost(cm.tti, *a, cm.cost_kind);
}
// getVectorCallCost
lv_cm_vector_call_cost :: (cm: *Lv_Cm, ci: Value_Id, vf: Ec) -> Cost {
    scalar_call := lv_tti_call_instr_cost(cm.tti);
    c := ifx vf.scalable then COST_INVALID else lc_add(lc_mul(scalar_call, cast(s64) vf.n), lv_cm_scalarization_overhead(cm, ci, vf));
    if get_vector_intrinsic_id_for_call(ci) != NOT_INTRINSIC {
        ic := lv_cm_vector_intrinsic_cost(cm, ci, vf);
        if ic < c c = ic;
    }
    // vector library variants: legality fails loudly on calls with VFDatabase mappings
    return c;
}

// shouldConsiderInvariant
lv_cm_should_consider_invariant :: (cm: *Lv_Cm, v: Value_Id) -> bool {
    if !lvl_is_invariant(cm.lvl, v) return false;
    if !is_inst(v) || !li_contains_inst(cm.li, cm.l, v) return true;
    if lv_cm_is_predicated_inst(cm, v) return false;
    if inst_op(v) == .PHI && inst_block(v) == li_header(cm.li, cm.l) return false;
    for k: 0..cast(s64) nops(v) - 1 if !lv_cm_should_consider_invariant(cm, op(v, cast(u32) k)) return false;
    return true;
}

// LoopVectorizationCostModel::getInstructionCost
lv_cm_instruction_cost :: (cm: *Lv_Cm, i: Value_Id, vf_in: Ec) -> Cost {
    vf := vf_in;
    t := cm.tti; kind := cm.cost_kind;
    if lv_cm_is_uniform_after_vectorization(cm, i, vf) vf = ec_fixed(1);
    if ec_is_vector(vf) && lv_cm_is_profitable_to_scalarize(cm, i, vf) return lv_cm_scalarize_cost(cm, i, vf);
    if ec_is_vector(vf) && lv_cm_is_forced_scalar(cm, i, vf) return lc_mul(lv_cm_instruction_cost(cm, i, ec_fixed(1)), cast(s64) vf.n);
    ret_ty := vtype(i);
    if lv_cm_can_truncate_to_minimal_bitwidth(cm, i, vf) { _, bw := lv_cm_min_bw(cm, i); ret_ty = type_int(bw); }
    vec_ty: Type_Id;
    if lv_cm_is_scalar_after_vectorization(cm, i, vf) vec_ty = ret_ty;
    else vec_ty = lv_to_vectorized_ty(ret_ty, vf);
    if ec_is_vector(vf) && is_vector_type(vec_ty) && lv_tti_number_of_parts(t, vec_ty) == 0 return COST_INVALID;
    o := inst_op(i);
    if o == {
    case .GEP; return 0;
    case .BR; #through;
    case .CONDBR;
        scalar_pred_bb := false;
        if ec_is_vector(vf) && o == .CONDBR && inst_block(i) != li_loop_latch(cm.li, cm.l) {
            st := lv_cm_vf_state(cm, vf);
            if iset_has(*st.predicated_bbs, get_successor(i, 0)) || iset_has(*st.predicated_bbs, get_successor(i, 1)) scalar_pred_bb = true;
        }
        if scalar_pred_bb {
            if vf.scalable return COST_INVALID;
            return lc_add(lv_tti_scalarization_overhead_all(t, type_vector(vf.n, type_int(1), false), false, true, kind),
                          lc_mul(lt_cf_cost(t, .CONDBR, kind), cast(s64) vf.n));
        }
        if inst_block(i) == li_loop_latch(cm.li, cm.l) || ec_is_scalar(vf) return lt_cf_cost(t, .BR, kind);
        return 0;
    case .SWITCH;
        if ec_is_scalar(vf) return lt_cf_cost(t, .SWITCH, kind);
        cond_ty := vtype(op(i, 0));
        return lc_mul(lt_cmp_sel_cost(t, .ICMP, lv_to_vector_ty(cond_ty, vf), lv_to_vector_ty(type_int(1), vf), ICMP_EQ, kind),
                      cast(s64) switch_num_cases(i));
    case .PHI;
        if ec_is_vector(vf) && lvl_is_fixed_order_recurrence(cm.lvl, i) return lv_tti_shuffle(t, SK_SPLICE, vec_ty, kind, -1);
        if ec_is_vector(vf) && inst_block(i) != li_header(cm.li, cm.l) {
            res_ty := vtype(i);
            // find_singleton header-phi user
            hu: Value_Id = NONE; multiple := false;
            u := ir.v_first_use[i];
            while u != NONE {
                usr := ir.u_user[u];
                if is_phi(usr) && inst_block(usr) == li_header(cm.li, cm.l) {
                    if hu != NONE && hu != usr multiple = true;
                    hu = usr;
                }
                u = ir.u_next[u];
            }
            if multiple hu = NONE;
            if hu != NONE {
                rd := lvl_find_reduction(cm.lvl, hu);
                if rd && rk_is_any_of(rd.kind) res_ty = type_int(1);
            }
            return lc_mul(lt_cmp_sel_cost(t, .SELECT, lv_to_vector_ty(res_ty, vf), lv_to_vector_ty(type_int(1), vf), BAD_ICMP_PREDICATE, kind),
                          cast(s64) nops(i) - 1);
        }
        if ec_is_vector(vf) && lv_cm_fold_tail_with_evl(cm) vp_unported("EVL tail folding (vp.merge phi costs)");
        return lt_cf_cost(t, .PHI, kind);
    case .UDIV; #through; case .SDIV; #through; case .UREM; #through; case .SREM;
        if ec_is_vector(vf) && lv_cm_is_predicated_inst(cm, i) {
            sc, mc := lv_cm_div_rem_speculation_cost(cm, i, vf);
            return ifx lv_cm_is_div_rem_scalar_with_predication(sc, mc) then sc else mc;
        }
        return lv_cm_arith_instruction_cost(cm, i, vf, vec_ty);
    case .ADD; #through; case .SUB; #through; case .FADD; #through; case .FSUB; #through; case .MUL; #through;
    case .FMUL; #through; case .FDIV; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through;
    case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR;
        return lv_cm_arith_instruction_cost(cm, i, vf, vec_ty);
    case .FNEG;
        return lt_arith_cost(t, .FNEG, vec_ty, kind, OI_ANY, OI_ANY, .[op(i, 0)], i);
    case .SELECT;
        cond := op(i, 0);
        scalar_cond := sc_is_loop_invariant(sc_get_scev(cond), cm.l);
        if !scalar_cond {
            ok_and, a0, a1 := pm_logical_and(i);
            ok_or, b0, b1 := pm_logical_or(i);
            if ok_and || ok_or {
                x := ifx ok_and then a0 else b0;
                y := ifx ok_and then a1 else b1;
                return lt_arith_cost(t, ifx ok_or then Opcode.OR else .AND, vec_ty, kind, tti_operand_info(x), tti_operand_info(y), .[x, y], i);
            }
        }
        cond_ty := vtype(cond);
        if !scalar_cond cond_ty = type_vector(vf.n, cond_ty, vf.scalable);
        pred: u8 = BAD_ICMP_PREDICATE;
        if is_inst(cond) && (inst_op(cond) == .ICMP || inst_op(cond) == .FCMP) pred = inst_pred(cond);
        return lt_cmp_sel_cost(t, .SELECT, vec_ty, cond_ty, pred, kind, OI_ANY, OI_ANY, i);
    case .ICMP; #through; case .FCMP;
        val_ty := vtype(op(i, 0));
        if lv_cm_can_truncate_to_minimal_bitwidth(cm, i, vf) { _, bw := lv_cm_min_bw(cm, i); val_ty = type_int(bw); }
        vt := lv_to_vector_ty(val_ty, vf);
        return lt_cmp_sel_cost(t, o, vt, lv_cmp_result_type(vt), inst_pred(i), kind, OI_ANY, OI_ANY, i);
    case .STORE; #through; case .LOAD;
        if ec_is_vector(vf) {
            d := lv_cm_widening_decision(cm, i, vf);
            assert(d != .UNKNOWN, "CM decision should be taken at this point");
            if !cost_valid(lv_cm_widening_cost(cm, i, vf)) return COST_INVALID;
        }
        return lv_cm_memory_instruction_cost(cm, i, vf);
    case .BITCAST;
        if type_kind(vtype(i)) == .PTR return 0;
        return lv_cm_cast_instruction_cost(cm, i, vf, vec_ty);
    case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through; case .FPEXT; #through;
    case .PTRTOINT; #through; case .INTTOPTR; #through; case .SITOFP; #through; case .UITOFP; #through;
    case .TRUNC; #through; case .FPTRUNC;
        return lv_cm_cast_instruction_cost(cm, i, vf, vec_ty);
    case .CALL;
        return lv_cm_vector_call_cost(cm, i, vf);
    case .EXTRACTVALUE;
        return lt_instruction_cost(t, i, kind);
    case .ALLOCA;
        if vf.scalable return COST_INVALID;
        return lt_arith_cost(t, .MUL, ret_ty, kind);
    case .FREEZE;
        return TCC_FREE;
    }
    return lt_arith_cost(t, .MUL, vec_ty, kind);
}
// CmpInst::makeCmpResultType
lv_cmp_result_type :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_vector(type_count(t), type_int(1), type_kind(t) == .SVECTOR);
    return type_int(1);
}

lv_cm_arith_instruction_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec, vec_ty: Type_Id) -> Cost {
    t := cm.tti; kind := cm.cost_kind;
    o := inst_op(i);
    // histograms are not supported (legality rejects them without -enable-histogram-loop-vectorization)
    if o == .MUL {
        a := op(i, 0); b := op(i, 1);
        if (li_is_loop_invariant(cm.li, cm.l, a) && sc_is_one(pse_get_scev(cm.pse, a))) ||
           (li_is_loop_invariant(cm.li, cm.l, b) && sc_is_one(pse_get_scev(cm.pse, b)))
            return 0;
    }
    if cm.has_in_loop_reductions && ec_is_vector(vf) vp_unported("in-loop reduction costs (getReductionPatternCost)");
    op2 := op(i, 1);
    if !is_const(op2) && li_is_loop_invariant(cm.li, cm.l, op2) && sc_is_scevable(vtype(op2)) {
        s := pse_get_scev(cm.pse, op2);
        if sc_is_const(s) op2 = sc_value(s);
    }
    op2_info := tti_operand_info(op2);
    if op2_info.kind == OK_ANY_VALUE && lv_cm_should_consider_invariant(cm, op2) op2_info.kind = OK_UNIFORM_VALUE;
    return lt_arith_cost(t, o, vec_ty, kind, OI_ANY, op2_info, lv_inst_operands(i, false), i);
}

lv_cm_cast_instruction_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec, vec_ty: Type_Id) -> Cost {
    t := cm.tti; kind := cm.cost_kind;
    compute_cch :: (cm: *Lv_Cm, m: Value_Id, vf: Ec) -> u8 {
        if ec_is_scalar(vf) || !li_contains_inst(cm.li, cm.l, m) return CCH_NORMAL;
        d := lv_cm_widening_decision(cm, m, vf);
        if d == {
            case .GATHER_SCATTER; return CCH_GATHER_SCATTER;
            case .INTERLEAVE; return CCH_INTERLEAVE;
            case .SCALARIZE; #through;
            case .WIDEN; return ifx lv_cm_is_predicated_inst(cm, m) then cast(u8) CCH_MASKED else CCH_NORMAL;
            case .WIDEN_REVERSE; return CCH_REVERSED;
            case .INVALIDATED; return CCH_NONE;
        }
        fatal("internal: instruction did not go through cost modelling");
        return CCH_NONE;
    }
    o := inst_op(i);
    cch: u8 = CCH_NONE;
    if o == .TRUNC || o == .FPTRUNC {
        if has_one_use(i) {
            usr := ir.u_user[ir.v_first_use[i]];
            if inst_op(usr) == .STORE cch = compute_cch(cm, usr, vf);
        }
    } else if o == .ZEXT || o == .SEXT || o == .FPEXT {
        src := op(i, 0);
        if is_inst(src) && inst_op(src) == .LOAD cch = compute_cch(cm, src, vf);
    }
    if lv_cm_is_optimizable_iv_truncate(cm, i, vf) return lt_cast_cost(t, .TRUNC, vtype(i), vtype(op(i, 0)), cch, kind, i);
    if cm.has_in_loop_reductions && ec_is_vector(vf) vp_unported("in-loop reduction costs (getReductionPatternCost)");
    src_scalar := vtype(op(i, 0));
    op0 := op(i, 0);
    if is_inst(op0) && lv_cm_can_truncate_to_minimal_bitwidth(cm, op0, vf) { _, bw := lv_cm_min_bw(cm, op0); src_scalar = type_int(bw); }
    src_vec := ifx is_vector_type(vec_ty) then lv_to_vector_ty(src_scalar, vf) else src_scalar;
    if lv_cm_can_truncate_to_minimal_bitwidth(cm, i, vf) {
        if type_bits(scalar_type(vec_ty)) <= type_bits(scalar_type(src_vec)) && (o == .ZEXT || o == .SEXT) return 0;
    }
    return lt_cast_cost(t, o, vec_ty, src_vec, cch, kind, i);
}

// ---------------------------------------------------------------- collectInstsToScalarize

// computePredInstDiscount: the discount, and the scalar costs of the chain (in visit order)
lv_cm_compute_pred_inst_discount :: (cm: *Lv_Cm, pred_inst: Value_Id, vf: Ec, keys: *[..] Value_Id, costs: *[..] Cost) -> Cost {
    t := cm.tti; kind := cm.cost_kind;
    discount: Cost = 0;
    wl: [..] Value_Id; wl.allocator = temp;
    can_be_scalarized :: (cm: *Lv_Cm, pred_inst: Value_Id, i: Value_Id, vf: Ec) -> bool {
        if !has_one_use(i) || inst_block(pred_inst) != inst_block(i) || lv_cm_is_scalar_after_vectorization(cm, i, vf) return false;
        if lv_cm_is_scalar_with_predication(cm, i, vf) return false;
        for k: 0..cast(s64) nops(i) - 1 {
            j := op(i, cast(u32) k);
            if is_inst(j) && lv_cm_is_uniform_after_vectorization(cm, j, vf) return false;
        }
        return true;
    }
    array_add(*wl, pred_inst);
    n := cast(s64) vf.n;
    while wl.count {
        i := pop(*wl);
        if array_find(keys.*, i) continue;
        if is_phi(i) && lvl_is_fixed_order_recurrence(cm.lvl, i) continue;
        vector_cost := lv_cm_instruction_cost(cm, i, vf);
        scalar_cost := lc_mul(lv_cm_instruction_cost(cm, i, ec_fixed(1)), n);
        if lv_cm_is_scalar_with_predication(cm, i, vf) && type_kind(vtype(i)) != .VOID {
            wide := lv_to_vectorized_ty(vtype(i), vf);
            scalar_cost = lc_add(scalar_cost, lv_tti_scalarization_overhead_all(t, wide, true, false, kind));
            scalar_cost = lc_add(scalar_cost, lc_mul(lt_cf_cost(t, .PHI, kind), n));
        }
        nk := ifx is_call_base(i) then nops(i) else nops(i);
        for k: 0..cast(s64) nk - 1 {
            j := op(i, cast(u32) k);
            if !is_inst(j) continue;
            if can_be_scalarized(cm, pred_inst, j, vf) array_add(*wl, j);
            else if lv_cm_needs_extract(cm, j, vf) {
                wide := lv_to_vectorized_ty(vtype(j), vf);
                scalar_cost = lc_add(scalar_cost, lv_tti_scalarization_overhead_all(t, wide, false, true, kind));
            }
        }
        scalar_cost = lc_div(scalar_cost, lv_cm_pred_block_cost_divisor(cm, inst_block(i)));
        discount = lc_add(discount, lc_sub(vector_cost, scalar_cost));
        array_add(keys, i); array_add(costs, scalar_cost);
    }
    return discount;
}

// collectInstsToScalarize
lv_cm_collect_insts_to_scalarize :: (cm: *Lv_Cm, vf: Ec) {
    st := lv_cm_vf_state(cm, vf, true);
    for bb: li_blocks(cm.li, cm.l) {
        if !lv_cm_block_needs_predication_for_any_reason(cm, bb) continue;
        for i: block_insts(bb) {
            if !lv_cm_is_scalar_with_predication(cm, i, vf) continue;
            keys: [..] Value_Id; keys.allocator = temp;
            costs: [..] Cost; costs.allocator = temp;
            if !lv_cm_is_scalar_after_vectorization(cm, i, vf) && !vf.scalable && !lv_cm_use_emulated_mask_mem_ref_hack(cm, i, vf) {
                d := lv_cm_compute_pred_inst_discount(cm, i, vf, *keys, *costs);
                // Discount >= 0 (an invalid discount compares greater than every valid cost)
                if d >= 0 {
                    for k: keys {
                        if array_find(st.insts_to_scalarize, k) continue;   // MapVector::insert keeps the first
                        array_add(*st.insts_to_scalarize, k);
                        array_add(*st.insts_to_scalarize_cost, costs[it_index]);
                    }
                }
            }
            iset_insert(*st.predicated_bbs, bb);
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(bb, *preds);
            for p: preds if block_get_single_successor(p) == bb iset_insert(*st.predicated_bbs, p);
        }
    }
}

// ---------------------------------------------------------------- expectedCost

// expectedCost (only for the scalar VF)
lv_cm_expected_cost :: (cm: *Lv_Cm, vf: Ec) -> Cost {
    assert(ec_is_scalar(vf), "must only be called for scalar VFs");
    c: Cost = 0;
    for bb: li_blocks(cm.li, cm.l) {
        bc: Cost = 0;
        for i: block_insts(bb) {
            if iset_has(*cm.values_to_ignore, i) continue;
            ic := lv_cm_instruction_cost(cm, i, vf);
            if cost_valid(ic) && lv_opts.force_target_instruction_cost.set ic = lv_forced_cost();
            lv_dbg("LV: Found an estimated cost of % for VF % For instruction: %\n", lc_str(ic), lv_ec_str(vf), lv_inst_str(i));
            bc = lc_add(bc, ic);
        }
        c = lc_add(c, lc_div(bc, lv_cm_pred_block_cost_divisor(cm, bb)));
    }
    return c;
}
lv_inst_str :: (i: Value_Id) -> string {
    n := ir.v_name[i];
    if n.count return tprint("%%= %", "%", n, inst_op(i));
    return tprint("%", inst_op(i));
}

// ---------------------------------------------------------------- interleave groups

// interleavedAccessCanBeWidened
lv_cm_interleaved_access_can_be_widened :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    g := iai_group(cm.iai, i);
    sty := load_store_type(i);
    if lv_has_irregular_type(sty) return false;
    if vf.scalable && g.factor > 8 return false;
    scalar_ni := dl_is_non_integral_pointer_type(sty);
    for m: ig_members(g) {
        mty := load_store_type(m);
        member_ni := dl_is_non_integral_pointer_type(mty);
        if member_ni != scalar_ni return false;
        if member_ni && scalar_ni && ptr_addrspace(sty) != ptr_addrspace(mty) return false;
    }
    pred_masking := lv_cm_block_needs_predication_for_any_reason(cm, inst_block(i)) && lv_cm_is_mask_required(cm, i);
    load_gaps := inst_op(i) == .LOAD && ig_requires_scalar_epilogue(g) && cm.sel != .ALLOWED;
    store_gaps := inst_op(i) == .STORE && !ig_is_full(g);
    if !pred_masking && !load_gaps && !store_gaps return true;
    assert(lv_use_masked_interleaved_accesses(cm.tti), "Masked interleave-groups for predicated accesses are not enabled.");
    if g.reverse return false;
    if vf.scalable && (load_gaps || store_gaps) return false;
    return lv_is_legal_masked_load_or_store(cm, i, vf);
}
// getInterleaveGroupCost
lv_cm_interleave_group_cost :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Lc {
    g := iai_group(cm.iai, i);
    ip := g.insert_pos;
    val_ty := load_store_type(ip);
    vty := lv_to_vector_ty(val_ty, vf);
    as := ptr_addrspace(vtype(load_store_pointer_operand(ip)));
    wide := type_vector(vf.n * g.factor, val_ty, vf.scalable);
    indices: [..] u32; indices.allocator = temp;
    for k: 0..g.factor - 1 if ig_get_member(g, k) != NONE array_add(*indices, k);
    use_mask_for_gaps := (ig_requires_scalar_epilogue(g) && cm.sel != .ALLOWED) || (inst_op(i) == .STORE && !ig_is_full(g));
    c := lcv(tti_interleaved_memory_op_cost(cm.tti, inst_op(ip), wide, g.factor, indices, g.align, as, cm.cost_kind,
                                            lv_cm_is_mask_required(cm, i), use_mask_for_gaps));
    if g.reverse c = lc_add(c, lc_mul(lv_tti_shuffle(cm.tti, SK_REVERSE, vty, cm.cost_kind, 0), g.keys.count));
    return c;
}
