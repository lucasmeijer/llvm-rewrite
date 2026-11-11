// LoopVectorizationLegality, LoopVectorizeHints, LoopVectorizationRequirements.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorizationLegality.cpp and
// llvm/include/llvm/Transforms/Vectorize/LoopVectorizationLegality.h (LLVM 23.1.5).
// Remarks are not emitted (no -pass-remarks support); reportVectorizationFailure is a plain `return false`.
//
// Not ported (fail loudly when reached): outer-loop legality (VPlan-native path), uncountable early-exit loops
// (isVectorizableEarlyExitLoop needs isReadOnlyLoop), histograms (only with -enable-histogram-loop-vectorization),
// VFDatabase vector variants, TLI vector-library mappings.

// ---------------------------------------------------------------- cl::opts of LoopVectorizationLegality.cpp

lvl_opts: struct {
    enable_if_conversion := true;          // -enable-if-conversion
    allow_strided_pointer_ivs := false;    // -lv-strided-pointer-ivs
    hints_allow_reordering := true;        // -hints-allow-reordering
    scalable_vectorization: s64 = -1;      // -scalable-vectorization (SK_Unspecified)
    enable_histogram := false;             // -enable-histogram-loop-vectorization
    force_vector_interleave_set := false;  // VectorizerParams::isInterleaveForced (getNumOccurrences)
};
LV_MAX_INTERLEAVE_FACTOR :: 16;

// ---------------------------------------------------------------- LoopVectorizeHints

FK_UNDEFINED :: -1; FK_DISABLED :: 0; FK_ENABLED :: 1;
SK_UNSPECIFIED :: -1; SK_FIXED_WIDTH_ONLY :: 0; SK_PREFER_SCALABLE :: 1; SK_ALWAYS_SCALABLE :: 2;

Lv_Hints :: struct {
    li: *Loop_Info;
    l: Loop_Id;
    width: s64;
    interleave: s64;
    force: s64 = FK_UNDEFINED;
    is_vectorized: s64;
    predicate: s64 = FK_UNDEFINED;
    scalable: s64 = SK_UNSPECIFIED;
    potentially_unsafe: bool;
}

lvh_validate :: (name: string, v: u64) -> bool {
    pow2 :: (x: u64) -> bool { return x != 0 && (x & (x - 1)) == 0; }
    if name == "vectorize.width" return pow2(v) && v <= LAA_MAX_VECTOR_WIDTH;
    if name == "interleave.count" return pow2(v) && v <= LV_MAX_INTERLEAVE_FACTOR;
    if name == "vectorize.enable" return v <= 1;
    return v == 0 || v == 1;
}

// LoopVectorizeHints::LoopVectorizeHints(L, InterleaveOnlyWhenForced, ORE, TTI)
lvh_init :: (h: *Lv_Hints, li: *Loop_Info, l: Loop_Id, interleave_only_when_forced: bool, have_tti: bool) {
    h.li = li; h.l = l;
    h.width = laa_opts.force_vector_width;
    h.interleave = ifx interleave_only_when_forced then 1 else 0;
    // getHintsFromMetadata
    id := li_loop_id(li, l);
    if id != NONE {
        n := md_nops(id);
        for k: 1..cast(s64) n - 1 {
            m := md_op(id, cast(u32) k);
            if m == NONE continue;
            s: Md_Id = NONE;
            nargs := 0;
            arg: Md_Id = NONE;
            if md_is_node(m) {
                if md_nops(m) == 0 continue;
                s = md_op(m, 0);
                nargs = cast(s64) md_nops(m) - 1;
                if nargs >= 1 arg = md_op(m, 1);
            } else s = m;
            if s == NONE || ir.mds[s].kind != .STRING continue;
            if nargs != 1 continue;
            name := ir.mds[s].str;
            if !begins_with(name, "llvm.loop.") continue;
            name = slice(name, 10, name.count - 10);
            if arg == NONE || ir.mds[arg].kind != .VALUE continue;
            v := ir.mds[arg].value;
            if vkind(v) != .C_INT continue;
            val := cast(u64) cast,trunc(u32) const_int_zext(v);
            target: *s64 = null;
            if name == "vectorize.width" target = *h.width;
            else if name == "interleave.count" target = *h.interleave;
            else if name == "vectorize.enable" target = *h.force;
            else if name == "isvectorized" target = *h.is_vectorized;
            else if name == "vectorize.predicate.enable" target = *h.predicate;
            else if name == "vectorize.scalable.enable" target = *h.scalable;
            if target && lvh_validate(name, val) target.* = cast(s64) val;
        }
    }
    if lvl_opts.force_vector_interleave_set h.interleave = laa_opts.force_vector_interleave;
    if h.scalable == SK_UNSPECIFIED {
        // TTI->enableScalableVectorization() is false for X86 and NoTTI
        if have_tti h.scalable = SK_FIXED_WIDTH_ONLY;
        if h.width != 0 h.scalable = SK_FIXED_WIDTH_ONLY;
    }
    if lvl_opts.scalable_vectorization != SK_UNSPECIFIED h.scalable = lvl_opts.scalable_vectorization;
    if h.scalable == SK_UNSPECIFIED h.scalable = SK_FIXED_WIDTH_ONLY;
    if h.is_vectorized != 1 h.is_vectorized = ifx lvh_width(h) == 1 && !lvh_width_scalable(h) && lvh_interleave(h) == 1 then 1 else 0;
}
lvh_width :: (h: *Lv_Hints) -> u64 { return cast(u64) h.width; }
lvh_width_scalable :: (h: *Lv_Hints) -> bool { return h.scalable == SK_PREFER_SCALABLE || h.scalable == SK_ALWAYS_SCALABLE; }
lvh_interleave :: (h: *Lv_Hints) -> u64 {
    if h.interleave return cast(u64) h.interleave;
    if li_has_unroll_transformation(h.li, h.l) & TM_DISABLE return 1;
    return 0;
}
lvh_force :: (h: *Lv_Hints) -> s64 {
    if h.force == FK_UNDEFINED && li_has_disable_all_transforms_hint(h.li, h.l) return FK_DISABLED;
    return h.force;
}
lvh_is_potentially_unsafe :: (h: *Lv_Hints) -> bool { return lvh_force(h) != FK_ENABLED && h.potentially_unsafe; }
lvh_is_scalable_disabled :: (h: *Lv_Hints) -> bool { return h.scalable == SK_FIXED_WIDTH_ONLY; }
// LoopVectorizeHints::allowVectorization
lvh_allow_vectorization :: (h: *Lv_Hints, vectorize_only_when_forced: bool) -> bool {
    if lvh_force(h) == FK_DISABLED return false;
    if vectorize_only_when_forced && lvh_force(h) != FK_ENABLED return false;
    if h.is_vectorized == 1 return false;
    return true;
}
// LoopVectorizeHints::allowReordering
lvh_allow_reordering :: (h: *Lv_Hints) -> bool {
    return lvl_opts.hints_allow_reordering && (lvh_force(h) == FK_ENABLED || lvh_width(h) > 1);
}

// ---------------------------------------------------------------- LoopVectorizationLegality

Uncountable_Exit_Trait :: enum u8 { NONE; READ_ONLY; READ_WRITE; }

Lv_Induction :: struct { phi: Value_Id; d: Ind_Desc; }
Lv_Reduction :: struct { phi: Value_Id; d: Rdx_Desc; }

Lvl :: struct {
    f: Value_Id;
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    pse: *Pse;
    tti: *Tti;
    tli: *Tli;
    ac: *Assumption_Cache;
    db: *Demanded_Bits;
    hints: *Lv_Hints;
    allow_runtime_scev_checks: bool;
    laa: *Laa;                                  // LAI
    exact_fp_inst: Value_Id = NONE;             // LoopVectorizationRequirements::ExactFPMathInst
    primary_induction: Value_Id = NONE;
    widest_ind_ty: Type_Id = NONE;
    inductions: [..] Lv_Induction;              // MapVector<PHINode *, InductionDescriptor>
    reductions: [..] Lv_Reduction;              // MapVector<PHINode *, RecurrenceDescriptor>
    fixed_order_recurrences: [..] Value_Id;
    induction_casts_to_ignore: Iset;
    conditionally_executed_ops: Iset;
    tail_folded_masked_ops: Iset;
    countable_exiting_blocks: [..] Value_Id;
    uncountable_exit: Uncountable_Exit_Trait;
    vec_call_variants_found: bool;
}

lvl_init :: (v: *Lvl) {
    v.inductions.allocator = temp; v.reductions.allocator = temp; v.fixed_order_recurrences.allocator = temp;
    v.induction_casts_to_ignore = iset_new(); v.conditionally_executed_ops = iset_new(); v.tail_folded_masked_ops = iset_new();
    v.countable_exiting_blocks.allocator = temp;
}

lvl_add_exact_fp :: (v: *Lvl, i: Value_Id) { if v.exact_fp_inst == NONE v.exact_fp_inst = i; }

lvl_find_induction :: (v: *Lvl, phi: Value_Id) -> *Ind_Desc {
    for *v.inductions if it.phi == phi return *it.d;
    return null;
}
lvl_find_reduction :: (v: *Lvl, phi: Value_Id) -> *Rdx_Desc {
    for *v.reductions if it.phi == phi return *it.d;
    return null;
}
lvl_is_induction_phi :: (v: *Lvl, x: Value_Id) -> bool { return is_phi(x) && lvl_find_induction(v, x) != null; }
lvl_is_casted_induction_variable :: (v: *Lvl, x: Value_Id) -> bool { return is_inst(x) && iset_has(*v.induction_casts_to_ignore, x); }
lvl_is_induction_variable :: (v: *Lvl, x: Value_Id) -> bool { return lvl_is_induction_phi(v, x) || lvl_is_casted_induction_variable(v, x); }
lvl_is_reduction_variable :: (v: *Lvl, phi: Value_Id) -> bool { return lvl_find_reduction(v, phi) != null; }
lvl_is_fixed_order_recurrence :: (v: *Lvl, phi: Value_Id) -> bool { return array_find(v.fixed_order_recurrences, phi); }
lvl_has_uncountable_early_exit :: (v: *Lvl) -> bool { return v.uncountable_exit != .NONE; }
lvl_has_uncountable_exit_with_side_effects :: (v: *Lvl) -> bool { return v.uncountable_exit == .READ_WRITE; }
lvl_is_safe_for_any_store_load_forward_distances :: (v: *Lvl) -> bool {
    return v.laa.dc.max_store_load_forward_safe_distance_in_bits == 0xFFFF_FFFF_FFFF_FFFF;
}
lvl_is_safe_for_any_vector_width :: (v: *Lvl) -> bool {
    return v.laa.dc.max_safe_vector_width_in_bits == 0xFFFF_FFFF && lvl_is_safe_for_any_store_load_forward_distances(v);
}
lvl_max_safe_vector_width_in_bits :: (v: *Lvl) -> u64 { return v.laa.dc.max_safe_vector_width_in_bits; }
lvl_max_store_load_forward_safe_distance_in_bits :: (v: *Lvl) -> u64 { return v.laa.dc.max_store_load_forward_safe_distance_in_bits; }
lvl_needs_runtime_ptr_checks :: (v: *Lvl) -> bool { return v.laa.rt.need; }
lvl_is_mask_required :: (v: *Lvl, i: Value_Id, tail_folded: bool) -> bool {
    if tail_folded return iset_has(*v.tail_folded_masked_ops, i);
    return iset_has(*v.conditionally_executed_ops, i);
}
// LoopVectorizationLegality::isInvariant = LAI->isInvariant
lvl_is_invariant :: (v: *Lvl, x: Value_Id) -> bool { return laa_is_invariant(v.laa, x); }

// getInductionIntegerTy / getWiderInductionTy
lv_induction_integer_ty :: (t: Type_Id) -> Type_Id {
    if type_kind(t) == .PTR return dl_int_ptr_type(t);
    if type_bits(scalar_type(t)) < 32 return type_int(32);
    return t;
}
lv_wider_induction_ty :: (a: Type_Id, b: Type_Id) -> Type_Id {
    ta := lv_induction_integer_ty(a); tb := lv_induction_integer_ty(b);
    return ifx type_bits(ta) > type_bits(tb) then ta else tb;
}

// storeToSameAddress
lv_store_to_same_address :: (a: Value_Id, b: Value_Id) -> bool {
    if a == b return true;
    pa := op(a, 1); pb := op(b, 1);
    if pa == pb return true;
    return sc_get_scev(pa) == sc_get_scev(pb);
}

// LoopVectorizationLegality::isConsecutivePtr
lvl_is_consecutive_ptr :: (v: *Lvl, access_ty: Type_Id, ptr: Value_Id) -> s64 {
    empty: Table(Value_Id, Scev_Id); empty.allocator = temp;
    strides := ifx v.laa && v.allow_runtime_scev_checks then *v.laa.symbolic_strides else *empty;
    ok, stride := laa_get_ptr_stride_assume(v.pse, v.li, access_ty, ptr, v.l, v.dt, strides, v.allow_runtime_scev_checks, false);
    if !ok stride = 0;
    if stride == 1 || stride == -1 return stride;
    return 0;
}
// LoopVectorizationLegality::collectUnitStridePredicates
lvl_collect_unit_stride_predicates :: (v: *Lvl) {
    if !v.allow_runtime_scev_checks || !li_is_innermost(v.li, v.l) return;
    for bb: li_blocks(v.li, v.l) for i: block_insts(bb) {
        p := load_store_pointer_operand(i);
        if p != NONE lvl_is_consecutive_ptr(v, load_store_type(i), p);
    }
}

// LoopVectorizationLegality::addInductionPhi
lvl_add_induction_phi :: (v: *Lvl, phi: Value_Id, d: Ind_Desc) {
    e := lvl_find_induction(v, phi);
    if e e.* = d; else array_add(*v.inductions, .{phi, d});
    if d.casts.count iset_insert(*v.induction_casts_to_ignore, d.casts[0]);
    ty := vtype(phi);
    if type_kind(ty) == .INT || type_kind(ty) == .PTR {
        if v.widest_ind_ty == NONE v.widest_ind_ty = lv_induction_integer_ty(ty);
        else v.widest_ind_ty = lv_wider_induction_ty(ty, v.widest_ind_ty);
    }
    dd := d;
    step := ind_const_int_step(*dd);
    if d.kind == .INT && step != NONE && ap_is_one(const_ap(step)) && is_const(d.start) && is_null_value(d.start) {
        if v.primary_induction == NONE || ty == v.widest_ind_ty v.primary_induction = phi;
    }
}

// isTLIScalarize: vector-library mappings are not ported (TLI.isFunctionVectorizable is always false)
lv_is_tli_scalarize :: (c: Value_Id) -> bool { return false; }

// LoopVectorizationLegality::canVectorizeInstr
lvl_can_vectorize_instr :: (v: *Lvl, i: Value_Id) -> bool {
    bb := inst_block(i);
    header := li_header(v.li, v.l);
    if inst_op(i) == .PHI {
        ty := vtype(i);
        if type_kind(ty) != .INT && !is_fp_type(ty) && type_kind(ty) != .PTR return false;
        if bb != header return true;
        if phi_num_incoming(i) != 2 return false;
        rd: Rdx_Desc;
        if rdx_is_reduction_phi(i, v.li, v.l, *rd, v.db, v.ac, v.dt, true) {
            lvl_add_exact_fp(v, rd.exact_fp);
            e := lvl_find_reduction(v, i);
            if e e.* = rd; else array_add(*v.reductions, .{i, rd});
            return true;
        }
        disallowed :: (d: *Ind_Desc) -> bool {
            if lvl_opts.allow_strided_pointer_ivs return false;
            return d.kind == .PTR && ind_const_int_step(d) == NONE;
        }
        id: Ind_Desc;
        if ind_is_induction_phi(i, v.li, v.l, v.pse, *id) && !disallowed(*id) {
            lvl_add_induction_phi(v, i, id);
            lvl_add_exact_fp(v, ind_exact_fp_math_inst(*id));
            return true;
        }
        if rdx_is_fixed_order_recurrence(i, v.li, v.l, v.dt) {
            if !array_find(v.fixed_order_recurrences, i) array_add(*v.fixed_order_recurrences, i);
            return true;
        }
        id2: Ind_Desc;
        if ind_is_induction_phi(i, v.li, v.l, v.pse, *id2, true) && !disallowed(*id2) {
            lvl_add_induction_phi(v, i, id2);
            return true;
        }
        return false;
    }
    is_call := inst_op(i) == .CALL;
    if is_call {
        f := call_called_function(i);
        if call_has_vector_variants(i) fatal("loop-vectorize: calls with vector-function-abi-variant mappings (VFDatabase) are not supported yet");
        if get_vector_intrinsic_id_for_call(i) == NOT_INTRINSIC && !(f != NONE && lv_is_tli_scalarize(i)) return false;
        id := get_vector_intrinsic_id_for_call(i);
        for k: 0..cast(s64) call_num_args(i) - 1 {
            if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) {
                if !sc_is_loop_invariant(pse_get_scev(v.pse, op(i, cast(u32) k)), v.l) return false;
            }
        }
    }
    can_widen_ty :: (i: Value_Id) -> bool {
        t := vtype(i);
        if type_kind(t) != .STRUCT return can_vectorize_ty(t);
        if !(inst_op(i) == .CALL && can_vectorize_ty(t)) return false;
        u := ir.v_first_use[i];
        while u != NONE { if inst_op(ir.u_user[u]) != .EXTRACTVALUE return false; u = ir.u_next[u]; }
        return true;
    }
    o := inst_op(i);
    if !can_widen_ty(i) || (is_cast_op(o) && !vector_type_is_valid_element_type(vtype(op(i, 0)))) || o == .EXTRACTELEMENT return false;
    if o == .STORE {
        t := vtype(op(i, 0));
        if !vector_type_is_valid_element_type(t) return false;
        if get_metadata(i, md_kind_id("nontemporal")) != NONE {
            if !lv_tti_is_legal_nt(v.tti, type_vector(2, t, false), inst(i).align, true) return false;
        }
    } else if o == .LOAD {
        if get_metadata(i, md_kind_id("nontemporal")) != NONE {
            if !lv_tti_is_legal_nt(v.tti, type_vector(2, vtype(i), false), inst(i).align, false) return false;
        }
    } else if is_fp_type(vtype(i)) && (is_call || is_binary_op(o)) && !ivd_is_fast(i) {
        v.hints.potentially_unsafe = true;
    }
    return true;
}

// TTI::isLegalNTStore / isLegalNTLoad
lv_tti_is_legal_nt :: (t: *Tti, ty: Type_Id, align: u64, store: bool) -> bool {
    if t.kind == .X86 return ifx store then x86_is_legal_nt_store(*t.xl, ty, align) else x86_is_legal_nt_load(*t.xl, ty, align);
    size := dl_type_store_size(ty);
    return align >= size && size != 0 && (size & (size - 1)) == 0;
}

// LoopVectorizationLegality::canVectorizeInstrs
lvl_can_vectorize_instrs :: (v: *Lvl) -> bool {
    for bb: li_blocks(v.li, v.l) for i: block_insts(bb) if !lvl_can_vectorize_instr(v, i) return false;
    if v.primary_induction == NONE {
        if v.inductions.count == 0 return false;
        if v.widest_ind_ty == NONE return false;
    }
    if v.primary_induction != NONE && v.widest_ind_ty != vtype(v.primary_induction) v.primary_induction = NONE;
    return true;
}

// LoopVectorizationLegality::canVectorizeIndirectUnsafeDependences
lvl_can_vectorize_indirect_unsafe_dependences :: (v: *Lvl) -> bool {
    if !lvl_opts.enable_histogram return false;
    fatal("loop-vectorize: -enable-histogram-loop-vectorization is not supported yet");
    return false;
}

// LoopVectorizationLegality::isInvariantStoreOfReduction
lvl_is_invariant_store_of_reduction :: (v: *Lvl, si: Value_Id) -> bool {
    for v.reductions if it.d.intermediate_store == si return true;
    return false;
}
// LoopVectorizationLegality::isInvariantAddressOfReduction
lvl_is_invariant_address_of_reduction :: (v: *Lvl, x: Value_Id) -> bool {
    for v.reductions {
        if it.d.intermediate_store == NONE continue;
        a := op(it.d.intermediate_store, 1);
        if x == a || sc_get_scev(x) == sc_get_scev(a) return true;
    }
    return false;
}

// LoopVectorizationLegality::canVectorizeMemory
lvl_can_vectorize_memory :: (v: *Lvl) -> bool {
    v.laa = laa_cached_info(v.f, v.l, v.li, v.dt, v.ac, false);
    a := v.laa;
    if !a.can_vec_mem {
        if lvl_has_uncountable_exit_with_side_effects(v) return false;
        return lvl_can_vectorize_indirect_unsafe_dependences(v);
    }
    if a.has_load_store_dep_inv return false;
    if a.stores_to_invariant_addresses.count {
        for si: a.stores_to_invariant_addresses {
            if !lvl_is_invariant_store_of_reduction(v, si) continue;
            if lvl_block_needs_predication(v, inst_block(si)) return false;
            p := op(si, 1);
            if is_inst(p) && li_contains_inst(v.li, v.l, p) return false;
        }
        if a.has_store_store_dep_inv {
            unhandled: [..] Value_Id; unhandled.allocator = temp;
            for si: a.stores_to_invariant_addresses {
                if lvl_is_invariant_store_of_reduction(v, si) {
                    k := 0;
                    while k < unhandled.count {
                        x := unhandled[k];
                        if lv_store_to_same_address(si, x) && vtype(op(x, 0)) == vtype(op(si, 0)) array_ordered_remove_by_index(*unhandled, k);
                        else k += 1;
                    }
                    continue;
                }
                array_add(*unhandled, si);
            }
            if unhandled.count return false;
        }
    }
    pse_add_predicates(v.pse, a.pse.preds);
    return true;
}

// LoopVectorizationLegality::canVectorizeFPMath
lvl_can_vectorize_fp_math :: (v: *Lvl, enable_strict: bool) -> bool {
    if v.exact_fp_inst == NONE || lvh_allow_reordering(v.hints) return true;
    if !enable_strict return false;
    for *v.inductions if ind_exact_fp_math_inst(*it.d) != NONE return false;
    for v.reductions if it.d.exact_fp != NONE && !it.d.is_ordered return false;
    return true;
}

// LoopVectorizationLegality::blockNeedsPredication
lvl_block_needs_predication :: (v: *Lvl, bb: Value_Id) -> bool {
    latch := li_loop_latch(v.li, v.l);
    if latch == NONE return false;
    if lvl_has_uncountable_early_exit(v) return bb == latch;
    return laa_block_needs_predication(bb, v.li, v.l, v.dt);
}

// LoopVectorizationLegality::blockCanBePredicated
lvl_block_can_be_predicated :: (v: *Lvl, bb: Value_Id, safe_ptrs: *Iset, masked: *Iset) -> bool {
    for i: block_insts(bb) {
        if call_iid(i) == IID_ASSUME { iset_insert(masked, i); continue; }
        if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL continue;
        if inst_op(i) == .CALL && call_has_vector_variants(i)
            fatal("loop-vectorize: calls with vector-function-abi-variant mappings (VFDatabase) are not supported yet");
        if inst_op(i) == .LOAD {
            if !iset_has(safe_ptrs, op(i, 0)) iset_insert(masked, i);
            continue;
        }
        if inst_op(i) == .STORE { iset_insert(masked, i); continue; }
        if may_read_from_memory(i) || may_write_to_memory(i) || may_throw(i) return false;
    }
    return true;
}

// LoopVectorizationLegality::canVectorizeWithIfConvert
lvl_can_vectorize_with_if_convert :: (v: *Lvl) -> bool {
    if !lvl_opts.enable_if_conversion return false;
    safe := iset_new();
    for bb: li_blocks(v.li, v.l) {
        if !lvl_block_needs_predication(v, bb) {
            for i: block_insts(bb) { p := load_store_pointer_operand(i); if p != NONE iset_insert(*safe, p); }
            continue;
        }
        for i: block_insts(bb) {
            if inst_op(i) != .LOAD || is_vector_type(vtype(i)) || must_suppress_speculation(i) continue;
            if !lvl_can_speculate_pointer_op(v, op(i, 0)) continue;
            if lv_is_dereferenceable_and_aligned_in_loop(v, i) iset_insert(*safe, op(i, 0));
        }
    }
    for bb: li_blocks(v.li, v.l) {
        t := block_terminator(bb);
        if inst_op(t) == .SWITCH {
            if li_is_loop_exiting(v.li, v.l, bb) return false;
        } else if inst_op(t) != .BR && inst_op(t) != .CONDBR return false;
        if lvl_block_needs_predication(v, bb) && !lvl_block_can_be_predicated(v, bb, *safe, *v.conditionally_executed_ops) return false;
    }
    return true;
}
// canVectorizeWithIfConvert's CanSpeculatePointerOp
lvl_can_speculate_pointer_op :: (v: *Lvl, ptr: Value_Id) -> bool {
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, ptr);
    visited := iset_new();
    while wl.count {
        cur := pop(*wl);
        if !iset_insert(*visited, cur) continue;
        if !is_inst(cur) || !li_contains_inst(v.li, v.l, cur) {
            pred := li_loop_predecessor(v.li, v.l);
            ctx := ifx pred != NONE then block_terminator(pred) else NONE;
            if !is_guaranteed_not_to_be_poison(cur, v.ac, ctx, v.dt) return false;
            continue;
        }
        if inst_op(cur) == .LOAD && !is_guaranteed_not_to_be_poison(cur, v.ac) return false;
        if inst_op(cur) != .PHI && !lv_is_safe_to_speculatively_execute(cur) return false;
        for k: 0..cast(s64) nops(cur) - 1 array_add(*wl, op(cur, cast(u32) k));
    }
    return true;
}

// isDereferenceableAndAlignedInLoop(LoadInst *, Loop *, SE, DT, AC, &Predicates) (Loads.cpp)
lv_is_dereferenceable_and_aligned_in_loop :: (v: *Lvl, ld: Value_Id) -> bool {
    l := v.l;
    ptr := op(ld, 0);
    ptr_scev := sc_get_scev(ptr);
    elt_size := ap_from_u64(dl_index_type_size_bits(vtype(ptr)), dl_type_store_size(vtype(ld)));
    align := load_store_align(ld);
    header := li_header(v.li, l);
    if li_is_loop_invariant(v.li, l, ptr) {
        q: Simplify_Query;
        q.dt = v.dt; q.ac = v.ac; q.cxt = block_first_non_phi(header);
        return is_dereferenceable_and_aligned_pointer(ptr, align, elt_size, q);
    }
    ar := ptr_scev;
    if !sc_is_addrec(ar) || sc_loop(ar) != l || !sc_is_affine(ar) return false;
    step := sc_step_recurrence(ar);
    if !sc_is_const(step) return false;
    if ap_zext_value(ap_urem(elt_size, ap_from_u64(elt_size.bits, align))) != 0 return false;
    sa := sc_ap(step);
    abs_step := ifx ap_is_negative(sa) then ap_neg(sa) else sa;
    if elt_size.bits != abs_step.bits vp_unported("isDereferenceableAndAlignedInLoop with a step wider or narrower than the index type");
    if ap_ugt(elt_size, abs_step) return false;
    preds: [..] u32; preds.allocator = temp;
    max_be := sc_get_predicated_symbolic_max_backedge_taken_count(l, *preds);
    be := sc_get_predicated_backedge_taken_count(l, *preds);
    if sc_is_cnc(max_be) return false;
    lg: Laa_Loop_Guards;
    elt_scev := sc_get_constant(elt_size);
    a_start, a_end := laa_start_and_end_for_access_size(l, ptr_scev, elt_scev, be, max_be, null, v.dt, v.ac, *lg);
    if sc_is_cnc(a_start) || sc_is_cnc(a_end) return false;
    diff := sc_get_minus(a_end, a_start);
    if sc_is_cnc(diff) return false;
    g := laa_guards(*lg, sc_loop(ar));
    max_diff := cr_umax(sc_unsigned_range(sc_apply_loop_guards_with(diff, g)));
    base: Value_Id = NONE;
    access_size: APInt;
    access_size_scev: Scev_Id;
    if sc_is_unknown(a_start) {
        base = sc_value(a_start);
        access_size = max_diff;
        access_size_scev = diff;
    } else if sc_kind(a_start) == .ADD {
        if sc_nops(a_start) != 2 return false;
        off := sc_op(a_start, 0); nb := sc_op(a_start, 1);
        if !sc_is_const(off) || !sc_is_unknown(nb) return false;
        oa := sc_ap(off);
        if ap_is_negative(oa) return false;
        if ap_zext_value(ap_urem(oa, ap_from_u64(oa.bits, align))) != 0 return false;
        sum, overflow := ap_uadd_ov(max_diff, oa);
        if overflow return false;
        access_size = sum;
        access_size_scev = sc_get_add2(diff, off);
        base = sc_value(nb);
    } else return false;
    cxt := block_first_non_phi(header);
    lp := li_loop_predecessor(v.li, l);
    if lp != NONE { t := block_terminator(lp); if inst_op(t) == .BR || inst_op(t) == .CONDBR cxt = t; }
    q: Simplify_Query;
    q.dt = v.dt; q.ac = v.ac; q.cxt = cxt;
    if lv_deref_aligned_via_assumption_scev(base, align, q, access_size_scev, g) return true;
    return is_dereferenceable_and_aligned_pointer(base, align, access_size, q);
}
// isDereferenceableAndAlignedPointerViaAssumption with isDereferenceableAndAlignedInLoop's CheckSize (a SCEV
// comparison of the access size with the assumed dereferenceable size)
lv_deref_aligned_via_assumption_scev :: (ptr: Value_Id, align: u64, q: Simplify_Query, access_size: Scev_Id, g: *Loop_Guards) -> bool {
    if q.cxt == NONE return false;
    can_be_freed := value_can_be_freed(ptr);
    is_aligned := pointer_alignment(ptr) >= align;
    align_rk: u64 = 0; have_align := false;
    deref_rk: u64 = 0; have_deref := false;
    deref_val: Value_Id = NONE;
    for e: ac_assumptions_for(q.ac, ptr) {
        if vkind(e.assume) == .DEAD || e.index == AC_EXPR_RESULT_IDX continue;
        ok, rk := knowledge_from_bundle(e.assume, e.index);
        if !ok || rk.was_on != ptr continue;
        if !is_valid_assume_for_context(e.assume, q.cxt, q.dt) continue;
        if rk.kind == .Alignment { if !have_align || rk.arg > align_rk { align_rk = rk.arg; have_align = true; } }
        if (!can_be_freed || will_not_free_between(e.assume, q.cxt)) && rk.kind == .Dereferenceable {
            vp_unported("dereferenceable assumptions in isDereferenceableAndAlignedInLoop");
        }
        is_aligned |= have_align && align_rk >= align;
        if is_aligned && have_deref return true;
    }
    return false;
}

// LoopVectorizationLegality::canVectorizeLoopCFG
lvl_can_vectorize_loop_cfg :: (v: *Lvl, lp: Loop_Id) -> bool {
    if li_loop_preheader(v.li, lp) == NONE return false;
    if li_num_back_edges(v.li, lp) != 1 return false;
    latch := li_loop_latch(v.li, lp);
    if latch != NONE {
        t := block_terminator(latch);
        if inst_op(t) != .BR && inst_op(t) != .CONDBR return false;
    }
    return true;
}
lvl_can_vectorize_loop_nest_cfg :: (v: *Lvl, lp: Loop_Id) -> bool {
    if !lvl_can_vectorize_loop_cfg(v, lp) return false;
    for li_subloops(v.li, lp) if !lvl_can_vectorize_loop_nest_cfg(v, it) return false;
    return true;
}

// LoopVectorizationLegality::canVectorize
lvl_can_vectorize :: (v: *Lvl, use_vplan_native_path: bool) -> bool {
    if !lvl_can_vectorize_loop_nest_cfg(v, v.l) return false;
    if !li_is_innermost(v.li, v.l) fatal("loop-vectorize: outer-loop vectorization (VPlan-native path) is not supported yet");
    if li_blocks(v.li, v.l).count != 1 && !lvl_can_vectorize_with_if_convert(v) return false;
    if !lvl_can_vectorize_instrs(v) return false;
    if sc_is_cnc(pse_get_backedge_taken_count(v.pse)) {
        if li_exiting_block(v.li, v.l) != NONE return false;
        if !lvl_is_vectorizable_early_exit_loop(v) return false;
    }
    if !lvl_can_vectorize_memory(v) return false;
    if v.uncountable_exit != .NONE && v.laa.stores_to_invariant_addresses.count return false;
    return true;
}

// LoopVectorizationLegality::isVectorizableEarlyExitLoop: only the parts that reject the loop before the
// read-only / movable-load analysis are ported.
lvl_is_vectorizable_early_exit_loop :: (v: *Lvl) -> bool {
    latch := li_loop_latch(v.li, v.l);
    if latch == NONE return false;
    if v.reductions.count || v.fixed_order_recurrences.count return false;
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(v.li, v.l, *exiting);
    preds: [..] u32; preds.allocator = temp;
    uncountable: [..] Value_Id; uncountable.allocator = temp;
    for bb: exiting {
        ec := sc_get_predicated_exit_count(v.l, bb, *preds);
        if sc_is_cnc(ec) {
            if num_successors(block_terminator(bb)) != 2 return false;
            array_add(*uncountable, bb);
        } else array_add(*v.countable_exiting_blocks, bb);
    }
    preds.count = 0;
    if uncountable.count == 0 return false;
    if sc_is_cnc(sc_get_predicated_exit_count(v.l, latch, *preds)) return false;
    has_side_effects := false;
    for bb: li_blocks(v.li, v.l) for i: block_insts(bb) {
        if may_write_to_memory(i) {
            if inst_op(i) == .STORE && inst_is_simple(i) { has_side_effects = true; continue; }
            return false;
        }
        o := inst_op(i);
        if o != .LOAD && o != .STORE && o != .PHI && o != .BR && o != .CONDBR && !lv_is_safe_to_speculatively_execute(i) return false;
    }
    fatal("loop-vectorize: early-exit loops with uncountable exits are not supported yet");
    return false;
}

// LoopVectorizationLegality::canFoldTailByMasking
lvl_can_fold_tail_by_masking :: (v: *Lvl) -> bool {
    if li_exiting_block(v.li, v.l) != li_loop_latch(v.li, v.l) return false;
    safe := iset_new();
    tmp := iset_new();
    for bb: li_blocks(v.li, v.l) if !lvl_block_can_be_predicated(v, bb, *safe, *tmp) return false;
    return true;
}
// LoopVectorizationLegality::prepareToFoldTailByMasking
lvl_prepare_to_fold_tail_by_masking :: (v: *Lvl) {
    safe := iset_new();
    for bb: li_blocks(v.li, v.l) lvl_block_can_be_predicated(v, bb, *safe, *v.tail_folded_masked_ops);
}

// SCEVAddRecForUniformityRewriter::visit / visitAddRecExpr / visitUnknown / visitCouldNotCompute
sc_rw_uniformity_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    if rw.cannot_analyze || sc_is_loop_invariant(s, rw.l) return true, s;
    k := sc_kind(s);
    if k == .ADDREC {
        ty := sc_type(s);
        step := sc_step_recurrence(s);
        if !sc_is_loop_invariant(step, rw.l) { rw.cannot_analyze = true; return true, s; }
        new_step := sc_get_mul2(step, sc_get_constant(ap_from_u64(sc_type_bits(ty), rw.step_multiplier)));
        scaled := sc_get_mul2(step, sc_get_constant(ap_from_u64(sc_type_bits(ty), rw.offset)));
        new_start := sc_get_add2(sc_start(s), scaled);
        return true, sc_get_add_rec(new_start, new_step, rw.l, SF_ANY);
    }
    if k == .UNKNOWN || k == .CNC { rw.cannot_analyze = true; return true, s; }
    return false, s;
}
// SCEVAddRecForUniformityRewriter::rewrite
lv_uniformity_rewrite :: (s: Scev_Id, mult: u64, offset: u64, l: Loop_Id) -> Scev_Id {
    if !sc_expr_contains(s, .CONTAINS_UDIV, SCEV_NULL) return SCEV_CNC;
    rw: Sc_Rewriter;
    sc_rewriter_init(*rw, .UNIFORMITY);
    rw.step_multiplier = mult; rw.offset = offset; rw.l = l;
    r := sc_rewrite(*rw, s);
    if !rw.cannot_analyze return r;
    return SCEV_CNC;
}
// LoopVectorizationLegality::isUniform (vf = 0: std::nullopt)
lvl_is_uniform :: (v: *Lvl, x: Value_Id, vf: Ec, has_vf: bool) -> bool {
    if lvl_is_invariant(v, x) return true;
    if !has_vf || vf.scalable return false;
    if ec_is_scalar(vf) return true;
    if !sc_is_scevable(vtype(x)) return false;
    s := sc_get_scev(x);
    n := vf.n;
    first := lv_uniformity_rewrite(s, n, 0, v.l);
    if sc_is_cnc(first) return false;
    i := n - 1;
    while i >= 1 {
        if lv_uniformity_rewrite(s, n, i, v.l) != first return false;
        i -= 1;
    }
    return true;
}
// LoopVectorizationLegality::isUniformMemOp
lvl_is_uniform_mem_op :: (v: *Lvl, i: Value_Id, vf: Ec, has_vf: bool) -> bool {
    p := load_store_pointer_operand(i);
    if p == NONE return false;
    return lvl_is_uniform(v, p, vf, has_vf) && !lvl_block_needs_predication(v, inst_block(i));
}

// isSafeToSpeculativelyExecute(I) without a context instruction (loads: isDereferenceableAndAlignedPointer)
lv_is_safe_to_speculatively_execute :: (i: Value_Id) -> bool {
    if inst_op(i) == .LOAD {
        if must_suppress_speculation(i) return false;
        q: Simplify_Query;
        return is_dereferenceable_and_aligned_pointer_ty(op(i, 0), vtype(i), inst(i).align, q);
    }
    return is_safe_to_speculatively_execute(i);
}
