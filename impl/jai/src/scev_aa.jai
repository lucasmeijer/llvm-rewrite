// SCEVAAResult: ScalarEvolution-based alias analysis (-aa-pipeline=scev-aa).
// Port of llvm/lib/Analysis/ScalarEvolutionAliasAnalysis.cpp (LLVM 23.1.5): canComputePointerDiff,
// SCEVAAResult::alias, GetBaseValue; with ScalarEvolution::instructionCouldExistWithOperands.

// instructionCouldExistWithOperands
sc_instruction_could_exist_with_operands :: (a: Scev_Id, b: Scev_Id) -> bool {
    scope_a, precise_a := sc_get_defining_scope_bound_precise(.[a]);
    scope_b, precise_b := sc_get_defining_scope_bound_precise(.[b]);
    if !precise_a || !precise_b return false;
    return scope_a == scope_b || dt_dominates_inst(se.dt, scope_a, scope_b) || dt_dominates_inst(se.dt, scope_b, scope_a);
}

// GetBaseValue (NONE = nullptr)
scev_aa_base_value :: (s: Scev_Id) -> Value_Id {
    if sc_is_addrec(s) return scev_aa_base_value(sc_start(s));
    if sc_is_add(s) {
        last := sc_op(s, sc_nops(s) - 1);
        if sc_is_ptr(last) return scev_aa_base_value(last);
        return NONE;
    }
    if sc_is_unknown(s) return sc_value(s);
    return NONE;
}

// SCEVAAResult::alias
scev_aa_alias :: (q: *Aa_Query, a: Mem_Loc, b: Mem_Loc) -> Alias_Result {
    se = q.aar.se;
    if ls_is_zero(a.size) || ls_is_zero(b.size) return ar(AR_NO);
    as := sc_get_scev(a.ptr);
    bs := sc_get_scev(b.ptr);
    if as == bs return ar(AR_MUST);
    // canComputePointerDiff
    if sc_effective_type(sc_type(as)) == sc_effective_type(sc_type(bs)) && sc_instruction_could_exist_with_operands(as, bs) {
        bits := sc_bits(as);
        unknown_size :: 0xFFFF_FFFF_FFFF_FFFF;   // MemoryLocation::UnknownSize
        asize := ap_from_u64(bits, ifx ls_has_value(a.size) then ls_value(a.size) else unknown_size);
        bsize := ap_from_u64(bits, ifx ls_has_value(b.size) then ls_value(b.size) else unknown_size);
        aint := sc_get_ptr_to_int(as, sc_effective_type(sc_type(as)));
        bint := sc_get_ptr_to_int(bs, sc_effective_type(sc_type(bs)));
        if aint != SCEV_CNC && bint != SCEV_CNC { as = aint; bs = bint; }
        ba := sc_get_minus(bs, as);
        if ba != SCEV_CNC && ap_ule(asize, cr_umin(sc_unsigned_range(ba))) && ap_uge(ap_neg(bsize), cr_umax(sc_unsigned_range(ba)))
            return ar(AR_NO);
        ab := sc_get_minus(as, bs);
        if ab != SCEV_CNC && ap_ule(bsize, cr_umin(sc_unsigned_range(ab))) && ap_uge(ap_neg(asize), cr_umax(sc_unsigned_range(ab)))
            return ar(AR_NO);
    }
    ao := scev_aa_base_value(as);
    bo := scev_aa_base_value(bs);
    if (ao != NONE && ao != a.ptr) || (bo != NONE && bo != b.ptr) {
        la := ifx ao != NONE then mloc_before_or_after(ao) else a;
        lb := ifx bo != NONE then mloc_before_or_after(bo) else b;
        if scev_aa_alias(q, la, lb).kind == AR_NO return ar(AR_NO);
    }
    return ar(AR_MAY);
}
