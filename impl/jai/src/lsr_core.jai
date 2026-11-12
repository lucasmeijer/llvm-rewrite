// LoopStrengthReduce, part 1: port of llvm/lib/Transforms/Scalar/LoopStrengthReduce.cpp: MemAccessTy, Immediate
// (fixed offsets only: scalable immediates need vscale, which x86 never has; they fail loudly), RegUseTracker,
// Formula, DoInitialMatch, the sext/sdiv helpers, ExtractImmediate / ExtractSymbol, isAddressUse, getAccessType,
// isExistingPhi, isHighCostExpansion, getSetupCost, Cost (RateRegister, RatePrimaryRegister, RateFormula, Lose,
// isLess), LSRFixup, LSRUse, isAMCompletelyFolded / isLegalUse / getScalingFactorCost / isAlwaysFoldable with the
// X86TTIImpl hooks (isLSRCostLess, canMacroFuseCmp, getScalingFactorCost, isLegalAddressingMode, ...).
// The other parts: lsr_instance.jai (LSRInstance), lsr_rewrite.jai (expansion and rewriting), lsr_pass.jai.

lsr_cl: struct {
    enable_phi_elim := true;             // -enable-lsr-phielim
    insns_cost := true;                  // -lsr-insns-cost
    insns_cost_given := false;
    exp_narrow := false;                 // -lsr-exp-narrow
    filter_same_scaled_reg := true;      // -lsr-filter-same-scaled-reg
    complexity_limit: u64 = 0xFFFF;      // -lsr-complexity-limit
    setup_cost_depth_limit: u64 = 7;     // -lsr-setupcost-depth-limit
    drop_solution: s64 = -1;             // -lsr-drop-solution (cl::boolOrDefault: -1 unset)
    enable_vscale_immediates := true;
    drop_scaled_for_vscale := true;
    term_fold := false;                  // -lsr-term-fold (loop-term-fold is a separate pass)
}

// ---------------------------------------------------------------- MemAccessTy, Immediate

LSR_UNKNOWN_AS :: 0xFFFF_FFFF;
Lsr_Mem_Ty :: struct { mem_ty: Type_Id = NONE; as: u32 = LSR_UNKNOWN_AS; }
lsr_mem_unknown :: (as: u32 = LSR_UNKNOWN_AS) -> Lsr_Mem_Ty { return .{ir.t_void, as}; }

Lsr_Imm :: struct { v: s64; scalable: bool; }
IMM_ZERO :: Lsr_Imm.{0, false};
IMM_FIXED_MIN :: Lsr_Imm.{-0x7FFF_FFFF_FFFF_FFFF - 1, false};
IMM_FIXED_MAX :: Lsr_Imm.{0x7FFF_FFFF_FFFF_FFFF, false};
imm_fixed :: (v: s64) -> Lsr_Imm { return .{v, false}; }
imm_is_zero :: (a: Lsr_Imm) -> bool { return a.v == 0; }
imm_nz :: (a: Lsr_Imm) -> bool { return a.v != 0; }
imm_compatible :: (a: Lsr_Imm, b: Lsr_Imm) -> bool { return a.v == 0 || b.v == 0 || a.scalable == b.scalable; }
imm_add_unsigned :: (a: Lsr_Imm, b: Lsr_Imm) -> Lsr_Imm { return .{cast,no_check(s64) (cast,no_check(u64) a.v + cast,no_check(u64) b.v), a.scalable || b.scalable}; }
imm_sub_unsigned :: (a: Lsr_Imm, b: Lsr_Imm) -> Lsr_Imm { return .{cast,no_check(s64) (cast,no_check(u64) a.v - cast,no_check(u64) b.v), a.scalable || b.scalable}; }
imm_mul_unsigned :: (a: Lsr_Imm, r: s64) -> Lsr_Imm { return .{cast,no_check(s64) (cast,no_check(u64) a.v * cast,no_check(u64) r), a.scalable}; }
// FixedOrScalableQuantity::operator+ (same kind)
imm_add :: (a: Lsr_Imm, b: Lsr_Imm) -> Lsr_Imm { return .{cast,no_check(s64) (cast,no_check(u64) a.v + cast,no_check(u64) b.v), a.scalable || b.scalable}; }
imm_eq :: (a: Lsr_Imm, b: Lsr_Imm) -> bool { return a.v == b.v && a.scalable == b.scalable; }
// isKnownGT / isKnownLT
imm_known_gt :: (a: Lsr_Imm, b: Lsr_Imm) -> bool {
    if !a.scalable || b.scalable return a.v > b.v;
    return false;
}
imm_known_lt :: (a: Lsr_Imm, b: Lsr_Imm) -> bool {
    if a.scalable == b.scalable || !a.scalable return a.v < b.v;
    return false;
}
imm_is_min :: (a: Lsr_Imm) -> bool { return a.v == IMM_FIXED_MIN.v; }
imm_is_max :: (a: Lsr_Imm) -> bool { return a.v == IMM_FIXED_MAX.v; }
// Immediate::getSCEV / getNegativeSCEV / getUnknownSCEV
imm_scev :: (a: Lsr_Imm, ty: Type_Id) -> Scev_Id {
    if a.scalable fatal("loop-reduce: scalable immediates are not supported");
    return sc_get_constant_t(ty, cast,no_check(u64) a.v, true);
}
imm_neg_scev :: (a: Lsr_Imm, ty: Type_Id) -> Scev_Id {
    if a.scalable fatal("loop-reduce: scalable immediates are not supported");
    return sc_get_constant_t(ty, cast,no_check(u64) (0 - cast,no_check(u64) a.v), false);
}
imm_unknown_scev :: (a: Lsr_Imm, ty: Type_Id) -> Scev_Id {
    if a.scalable fatal("loop-reduce: scalable immediates are not supported");
    return sc_get_unknown(const_int(ty, cast,no_check(u64) a.v));   // ConstantInt::getSigned(Ty, Q, ImplicitTrunc)
}

// ---------------------------------------------------------------- RegUseTracker

Lsr_Reg_Uses :: struct {
    map: Table(Scev_Id, s64);       // RegUsesMap: register -> row of `used_by`
    used_by: [..] [..] bool;        // RegSortData::UsedByIndices (SmallBitVector)
    sequence: [..] Scev_Id;         // RegSequence
}
ru_count_register :: (r: *Lsr_Reg_Uses, reg: Scev_Id, lu: s64) {
    found, k := table_find(*r.map, reg);
    if !found {
        k = r.used_by.count;
        e: [..] bool; e.allocator = temp;
        array_add(*r.used_by, e);
        table_set(*r.map, reg, k);
        array_add(*r.sequence, reg);
    }
    b := *r.used_by[k];
    while b.count < lu + 1 array_add(b, false);
    b.*[lu] = true;
}
ru_drop_register :: (r: *Lsr_Reg_Uses, reg: Scev_Id, lu: s64) {
    _, k := table_find(*r.map, reg);
    r.used_by[k][lu] = false;
}
ru_swap_and_drop_use :: (r: *Lsr_Reg_Uses, lu: s64, last: s64) {
    for * b: r.used_by {
        if lu < b.count b.*[lu] = ifx last < b.count then b.*[last] else false;
        if b.count > last b.count = last;
    }
}
ru_is_reg_used_by_uses_other_than :: (r: *Lsr_Reg_Uses, reg: Scev_Id, lu: s64) -> bool {
    found, k := table_find(*r.map, reg);
    if !found return false;
    b := r.used_by[k];
    first := -1;
    for b if it { first = it_index; break; }
    if first == -1 return false;
    if first != lu return true;
    for i: first+1..b.count-1 if b[i] return true;
    return false;
}
ru_used_by :: (r: *Lsr_Reg_Uses, reg: Scev_Id) -> [] bool {
    found, k := table_find(*r.map, reg);
    if !found fatal("loop-reduce: Unknown register!");
    return r.used_by[k];
}

// ---------------------------------------------------------------- Formula

Lsr_Formula :: struct {
    base_gv: Value_Id = NONE;
    base_offset: Lsr_Imm;
    has_base_reg: bool;
    scale: s64;
    base_regs: [..] Scev_Id;
    scaled_reg: Scev_Id = SCEV_NULL;
    unfolded_offset: Lsr_Imm;
}
// a deep copy (Formula is a value type in LLVM)
lf_copy :: (f: *Lsr_Formula) -> Lsr_Formula {
    r := f.*;
    nb: [..] Scev_Id; nb.allocator = temp;
    r.base_regs = nb;
    for f.base_regs array_add(*r.base_regs, it);
    return r;
}
lf_new :: () -> Lsr_Formula { f: Lsr_Formula; f.base_regs.allocator = temp; return f; }

// DoInitialMatch
lsr_do_initial_match :: (s: Scev_Id, l: Loop_Id, good: *[..] Scev_Id, bad: *[..] Scev_Id) {
    if sc_properly_dominates(s, li_header(se.li, l)) { array_add(good, s); return; }
    if sc_kind(s) == .ADD {
        for k: 0..cast(s64) sc_nops(s) - 1 lsr_do_initial_match(sc_op(s, cast(u32) k), l, good, bad);
        return;
    }
    if sc_kind(s) == .ADDREC && sc_is_affine(s) && !sc_is_zero(sc_start(s)) {
        lsr_do_initial_match(sc_start(s), l, good, bad);
        lsr_do_initial_match(sc_get_add_rec(sc_get_constant_t(sc_type(s), 0), sc_op(s, 1), sc_loop(s), SF_ANY), l, good, bad);
        return;
    }
    if sc_kind(s) == .MUL && sc_is_all_ones(sc_op(s, 0)) {
        ops: [..] Scev_Id; ops.allocator = temp;
        for k: 1..cast(s64) sc_nops(s) - 1 array_add(*ops, sc_op(s, cast(u32) k));
        new_mul := sc_get_mul(*ops);
        my_good: [..] Scev_Id; my_good.allocator = temp;
        my_bad: [..] Scev_Id; my_bad.allocator = temp;
        lsr_do_initial_match(new_mul, l, *my_good, *my_bad);
        neg_one := sc_get_scev(cf_all_ones(sc_effective_type(sc_type(new_mul))));
        for my_good array_add(good, sc_get_mul2(neg_one, it));
        for my_bad array_add(bad, sc_get_mul2(neg_one, it));
        return;
    }
    array_add(bad, s);
}

// Formula::initialMatch
lf_initial_match :: (f: *Lsr_Formula, s: Scev_Id, l: Loop_Id) {
    good: [..] Scev_Id; good.allocator = temp;
    bad: [..] Scev_Id; bad.allocator = temp;
    lsr_do_initial_match(s, l, *good, *bad);
    if good.count {
        sum := sc_get_add(*good);
        if !sc_is_zero(sum) array_add(*f.base_regs, sum);
        f.has_base_reg = true;
    }
    if bad.count {
        sum := sc_get_add(*bad);
        if !sc_is_zero(sum) array_add(*f.base_regs, sum);
        f.has_base_reg = true;
    }
    lf_canonicalize(f, l);
}

// containsAddRecDependentOnLoop
lsr_contains_add_rec_dependent_on_loop :: (s: Scev_Id, l: Loop_Id) -> bool {
    work: [..] Scev_Id; work.allocator = temp;
    seen: Table(Scev_Id, bool); seen.allocator = temp;
    array_add(*work, s);
    while work.count {
        x := pop(*work);
        if table_contains(*seen, x) continue;
        table_set(*seen, x, true);
        if sc_kind(x) == .ADDREC && sc_loop(x) == l return true;
        for k: 0..cast(s64) sc_nops(x) - 1 array_add(*work, sc_op(x, cast(u32) k));
    }
    return false;
}

lf_is_canonical :: (f: *Lsr_Formula, l: Loop_Id) -> bool {
    if f.scaled_reg == SCEV_NULL return f.base_regs.count <= 1;
    if f.scale != 1 return true;
    if f.scale == 1 && f.base_regs.count == 0 return false;
    if lsr_contains_add_rec_dependent_on_loop(f.scaled_reg, l) return true;
    for f.base_regs if lsr_contains_add_rec_dependent_on_loop(it, l) return false;
    return true;
}

lf_canonicalize :: (f: *Lsr_Formula, l: Loop_Id) {
    if lf_is_canonical(f, l) return;
    if f.base_regs.count == 0 {
        array_add(*f.base_regs, f.scaled_reg);
        f.scale = 0;
        f.scaled_reg = SCEV_NULL;
        return;
    }
    if f.scaled_reg == SCEV_NULL {
        f.scaled_reg = pop(*f.base_regs);
        f.scale = 1;
    }
    if !lsr_contains_add_rec_dependent_on_loop(f.scaled_reg, l) {
        for * f.base_regs {
            if lsr_contains_add_rec_dependent_on_loop(it.*, l) {
                t := f.scaled_reg; f.scaled_reg = it.*; it.* = t;
                break;
            }
        }
    }
}

lf_unscale :: (f: *Lsr_Formula) -> bool {
    if f.scale != 1 return false;
    f.scale = 0;
    array_add(*f.base_regs, f.scaled_reg);
    f.scaled_reg = SCEV_NULL;
    return true;
}
lf_has_zero_end :: (f: *Lsr_Formula) -> bool {
    if imm_nz(f.unfolded_offset) || imm_nz(f.base_offset) return false;
    if f.base_regs.count != 1 || f.scaled_reg != SCEV_NULL return false;
    return true;
}
lf_counts_down_to_zero :: (f: *Lsr_Formula) -> bool {
    if !lf_has_zero_end(f) return false;
    r := f.base_regs[0];
    if !(sc_kind(r) == .ADDREC && sc_is_affine(r) && sc_is_const(sc_op(r, 1))) return false;
    return ap_is_negative(sc_ap(sc_op(r, 1)));
}
lf_num_regs :: (f: *Lsr_Formula) -> s64 { return (ifx f.scaled_reg != SCEV_NULL then 1 else 0) + f.base_regs.count; }
lf_type :: (f: *Lsr_Formula) -> Type_Id {
    if f.base_regs.count return sc_type(f.base_regs[0]);
    if f.scaled_reg != SCEV_NULL return sc_type(f.scaled_reg);
    if f.base_gv != NONE return vtype(f.base_gv);
    return NONE;
}
// deleteBaseReg(S): swap with the last element and pop
lf_delete_base_reg :: (f: *Lsr_Formula, idx: s64) {
    last := f.base_regs.count - 1;
    if idx != last { t := f.base_regs[idx]; f.base_regs[idx] = f.base_regs[last]; f.base_regs[last] = t; }
    f.base_regs.count -= 1;
}
lf_references_reg :: (f: *Lsr_Formula, s: Scev_Id) -> bool {
    if s == f.scaled_reg return true;
    for f.base_regs if it == s return true;
    return false;
}
lf_has_regs_used_by_uses_other_than :: (f: *Lsr_Formula, lu: s64, ru: *Lsr_Reg_Uses) -> bool {
    if f.scaled_reg != SCEV_NULL && ru_is_reg_used_by_uses_other_than(ru, f.scaled_reg, lu) return true;
    for f.base_regs if ru_is_reg_used_by_uses_other_than(ru, it, lu) return true;
    return false;
}

// ---------------------------------------------------------------- sext / exact sdiv

lsr_is_add_rec_sextable :: (ar: Scev_Id) -> bool {
    wide := type_int(sc_type_bits(sc_type(ar)) + 1);
    return sc_kind(sc_get_sign_extend(ar, wide)) == .ADDREC;
}
lsr_is_add_sextable :: (a: Scev_Id) -> bool {
    wide := type_int(sc_type_bits(sc_type(a)) + 1);
    return sc_kind(sc_get_sign_extend(a, wide)) == .ADD;
}
lsr_is_mul_sextable :: (m: Scev_Id) -> bool {
    wide := type_int(sc_type_bits(sc_type(m)) * sc_nops(m));
    return sc_kind(sc_get_sign_extend(m, wide)) == .MUL;
}

// getExactSDiv
lsr_get_exact_sdiv :: (lhs: Scev_Id, rhs: Scev_Id, ignore_significant_bits := false) -> Scev_Id {
    if lhs == rhs return sc_get_constant_t(sc_type(lhs), 1);
    rc := sc_is_const(rhs);
    if rc {
        ra := sc_ap(rhs);
        if ap_is_all_ones(ra) {
            if type_kind(sc_type(lhs)) == .PTR return SCEV_NULL;
            return sc_get_mul2(lhs, rhs);
        }
        if ap_is_one(ra) return lhs;
    }
    if sc_is_const(lhs) {
        if !rc return SCEV_NULL;
        la := sc_ap(lhs); ra := sc_ap(rhs);
        if !ap_is_zero(ap_srem(la, ra)) return SCEV_NULL;
        return sc_get_constant(ap_sdiv(la, ra));
    }
    k := sc_kind(lhs);
    if k == .ADDREC {
        if (ignore_significant_bits || lsr_is_add_rec_sextable(lhs)) && sc_is_affine(lhs) {
            step := lsr_get_exact_sdiv(sc_step_recurrence(lhs), rhs, ignore_significant_bits);
            if step == SCEV_NULL return SCEV_NULL;
            start := lsr_get_exact_sdiv(sc_start(lhs), rhs, ignore_significant_bits);
            if start == SCEV_NULL return SCEV_NULL;
            return sc_get_add_rec(start, step, sc_loop(lhs), SF_ANY);
        }
        return SCEV_NULL;
    }
    if k == .ADD {
        if ignore_significant_bits || lsr_is_add_sextable(lhs) {
            ops: [..] Scev_Id; ops.allocator = temp;
            for i: 0..cast(s64) sc_nops(lhs) - 1 {
                o := lsr_get_exact_sdiv(sc_op(lhs, cast(u32) i), rhs, ignore_significant_bits);
                if o == SCEV_NULL return SCEV_NULL;
                array_add(*ops, o);
            }
            return sc_get_add(*ops);
        }
        return SCEV_NULL;
    }
    if k == .MUL {
        if ignore_significant_bits || lsr_is_mul_sextable(lhs) {
            if sc_kind(rhs) == .MUL && (ignore_significant_bits || lsr_is_mul_sextable(rhs)) {
                lc := sc_op(lhs, 0); rc2 := sc_op(rhs, 0);
                if sc_is_const(lc) && sc_is_const(rc2) {
                    same := sc_nops(lhs) == sc_nops(rhs);
                    if same for i: 1..cast(s64) sc_nops(lhs) - 1 if sc_op(lhs, cast(u32) i) != sc_op(rhs, cast(u32) i) { same = false; break; }
                    if same return lsr_get_exact_sdiv(lc, rc2, ignore_significant_bits);
                }
            }
            ops: [..] Scev_Id; ops.allocator = temp;
            found := false;
            for i: 0..cast(s64) sc_nops(lhs) - 1 {
                s := sc_op(lhs, cast(u32) i);
                if !found {
                    q := lsr_get_exact_sdiv(s, rhs, ignore_significant_bits);
                    if q != SCEV_NULL { s = q; found = true; }
                }
                array_add(*ops, s);
            }
            return ifx found then sc_get_mul(*ops) else SCEV_NULL;
        }
        return SCEV_NULL;
    }
    return SCEV_NULL;
}

// ---------------------------------------------------------------- immediates and symbols

// ExtractImmediateOperand(Ops, SE, PreferScalable): Ops[0] may be replaced by zero
lsr_extract_immediate_operand :: (ops: [] Scev_Id) -> Lsr_Imm {
    result := IMM_ZERO;
    s := ops[0];
    if sc_is_const(s) {
        c := sc_ap(s);
        if !ap_is_zero(c) && ap_significant_bits(c) <= 64 {
            result = imm_fixed(ap_sext_value(c));
            ops[0] = sc_get_constant_t(sc_type(s), 0);
            return result;
        }
    }
    // scalable immediates: (vscale * C) operands before the first operand past scMulExpr
    for o: ops {
        if cast(u8) sc_kind(o) > cast(u8) Scev_Kind.MUL break;
        if sc_kind(o) == .MUL && sc_nops(o) == 2 && sc_is_const(sc_op(o, 0)) && sc_kind(sc_op(o, 1)) == .VSCALE
            fatal("loop-reduce: vscale immediates are not supported");
    }
    return result;
}
// ExtractImmediate(S): returns the immediate and the remaining expression
lsr_extract_immediate :: (s: *Scev_Id) -> Lsr_Imm {
    if sc_kind(s.*) == .ADD {
        ops := sc_operands(s.*);
        result := lsr_extract_immediate_operand(ops);
        if imm_is_zero(result) result = lsr_extract_immediate(*ops[0]);
        if imm_nz(result) s.* = sc_get_add(*ops);
        return result;
    }
    if sc_kind(s.*) == .ADDREC {
        ops := sc_operands(s.*);
        result := lsr_extract_immediate(*ops[0]);
        if imm_nz(result) s.* = sc_get_add_rec_ops(*ops, sc_loop(s.*), SF_ANY);
        return result;
    }
    one: [1] Scev_Id;
    one[0] = s.*;
    r := lsr_extract_immediate_operand(one);
    s.* = one[0];
    return r;
}
// ExtractSymbol(S)
lsr_extract_symbol :: (s: *Scev_Id) -> Value_Id {
    k := sc_kind(s.*);
    if k == .UNKNOWN {
        v := sc_value(s.*);
        if is_global_value(vkind(v)) {
            s.* = sc_get_constant_t(vtype(v), 0);
            return v;
        }
    } else if k == .ADD {
        ops := sc_operands(s.*);
        result := lsr_extract_symbol(*ops[ops.count - 1]);
        if result != NONE s.* = sc_get_add(*ops);
        return result;
    } else if k == .ADDREC {
        ops := sc_operands(s.*);
        result := lsr_extract_symbol(*ops[0]);
        if result != NONE s.* = sc_get_add_rec_ops(*ops, sc_loop(s.*), SF_ANY);
        return result;
    }
    return NONE;
}

// isAddressUse
lsr_is_address_use :: (i: Value_Id, operand: Value_Id) -> bool {
    o := inst_op(i);
    is_addr := o == .LOAD;
    if o == .STORE {
        if op(i, 1) == operand is_addr = true;
    } else if o == .CALL && call_iid(i) != NOT_INTRINSIC {
        id := call_iid(i);
        if id == IID_MEMSET || id == LSR_IID_PREFETCH || id == IID_MASKED_LOAD {
            if call_arg(i, 0) == operand is_addr = true;
        } else if id == IID_MASKED_STORE {
            if call_arg(i, 1) == operand is_addr = true;
        } else if id == IID_MEMMOVE || id == IID_MEMCPY {
            if call_arg(i, 0) == operand || call_arg(i, 1) == operand is_addr = true;
        } else {
            // TTI.getTgtMemIntrinsic: X86 recognizes no memory intrinsics here
        }
    } else if o == .ATOMICRMW || o == .CMPXCHG {
        if op(i, 0) == operand is_addr = true;
    }
    return is_addr;
}

// Instruction::getAccessType
inst_access_type_of :: (i: Value_Id) -> Type_Id {
    o := inst_op(i);
    if o == .LOAD return vtype(i);
    if o == .STORE return vtype(op(i, 0));
    if o == .ATOMICRMW return vtype(op(i, 1));
    if o == .CMPXCHG return vtype(op(i, 1));
    if o == .CALL {
        id := call_iid(i);
        if id == IID_MASKED_LOAD return vtype(i);
        if id == IID_MASKED_STORE return vtype(call_arg(i, 0));
    }
    return NONE;
}

// getAccessType
lsr_get_access_type :: (i: Value_Id, operand: Value_Id) -> Lsr_Mem_Ty {
    at := lsr_mem_unknown();
    t := inst_access_type_of(i);
    if t != NONE at.mem_ty = t;
    o := inst_op(i);
    if o == .STORE at.as = ptr_addrspace(vtype(op(i, 1)));
    else if o == .LOAD at.as = ptr_addrspace(vtype(op(i, 0)));
    else if o == .ATOMICRMW || o == .CMPXCHG at.as = ptr_addrspace(vtype(op(i, 0)));
    else if o == .CALL && call_iid(i) != NOT_INTRINSIC {
        id := call_iid(i);
        if id == LSR_IID_PREFETCH || id == IID_MEMSET {
            at.as = ptr_addrspace(vtype(call_arg(i, 0)));
            at.mem_ty = vtype(operand);
        } else if id == IID_MEMMOVE || id == IID_MEMCPY {
            at.as = ptr_addrspace(vtype(operand));
            at.mem_ty = vtype(operand);
        } else if id == IID_MASKED_LOAD {
            at.as = ptr_addrspace(vtype(call_arg(i, 0)));
        } else if id == IID_MASKED_STORE {
            at.as = ptr_addrspace(vtype(call_arg(i, 1)));
        }
    }
    return at;
}

// isExistingPhi
lsr_is_existing_phi :: (ar: Scev_Id) -> bool {
    for pn: block_insts(li_header(se.li, sc_loop(ar))) {
        if inst_op(pn) != .PHI break;
        if sc_is_scevable(vtype(pn)) && sc_effective_type(vtype(pn)) == sc_effective_type(sc_type(ar)) && sc_get_scev(pn) == ar return true;
    }
    return false;
}

// isHighCostExpansion
lsr_is_high_cost_expansion :: (s: Scev_Id, processed: *Table(Scev_Id, bool)) -> bool {
    k := sc_kind(s);
    if k == .UNKNOWN || k == .CONSTANT || k == .VSCALE return false;
    if k == .TRUNC || k == .ZEXT || k == .SEXT return lsr_is_high_cost_expansion(sc_op(s, 0), processed);
    if table_contains(processed, s) return false;
    table_set(processed, s, true);
    if k == .ADD {
        for i: 0..cast(s64) sc_nops(s) - 1 if lsr_is_high_cost_expansion(sc_op(s, cast(u32) i), processed) return true;
        return false;
    }
    if k == .MUL && sc_nops(s) == 2 {
        op0 := sc_op(s, 0); op1 := sc_op(s, 1);
        if sc_is_const(op0) return lsr_is_high_cost_expansion(op1, processed);
        if sc_kind(op1) == .UNKNOWN {
            uval := sc_value(op1);
            // ConstantData has no use list (LLVM 23)
            if !cgp_is_constant_data(uval) {
                u := ir.v_first_use[uval];
                while u != NONE {
                    ui := ir.u_user[u];
                    u = ir.u_next[u];
                    if is_inst(ui) && inst_op(ui) == .MUL && sc_is_scevable(vtype(ui)) return sc_get_scev(ui) == s;
                }
            }
        }
    }
    if k == .ADDREC && lsr_is_existing_phi(s) return false;
    return true;
}

// ---------------------------------------------------------------- LSRFixup, LSRUse

Lsr_Kind :: enum u8 { BASIC; SPECIAL; ADDRESS; ICMP_ZERO; }

Lsr_Fixup :: struct {
    user_inst: Value_Id = NONE;
    operand_val_to_replace: Value_Id = NONE;
    post_inc_loops: [..] Loop_Id;   // PostIncLoopSet (SmallPtrSet: membership; iteration via its order)
    offset: Lsr_Imm;
}

Lsr_Use :: struct {
    uniquifier: [..] [..] Scev_Id;   // DenseSet of sorted register lists
    kind: Lsr_Kind;
    access_ty: Lsr_Mem_Ty;
    fixups: [..] Lsr_Fixup;
    min_offset := IMM_FIXED_MAX;
    max_offset := IMM_FIXED_MIN;
    all_fixups_outside_loop := true;
    all_fixups_unconditional := true;
    rigid_formula := false;
    formulae: [..] Lsr_Formula;
    regs: [..] Scev_Id;              // SmallPtrSet (membership + an insertion-ordered list)
}
lsr_use_new :: (k: Lsr_Kind, at: Lsr_Mem_Ty) -> Lsr_Use {
    u: Lsr_Use;
    u.kind = k; u.access_ty = at;
    u.uniquifier.allocator = temp; u.fixups.allocator = temp; u.formulae.allocator = temp; u.regs.allocator = temp;
    return u;
}
lu_new_fixup :: (lu: *Lsr_Use) -> *Lsr_Fixup {
    f: Lsr_Fixup;
    f.post_inc_loops.allocator = temp;
    array_add(*lu.fixups, f);
    return *lu.fixups[lu.fixups.count - 1];
}
lu_push_fixup :: (lu: *Lsr_Use, f: Lsr_Fixup) {
    array_add(*lu.fixups, f);
    if imm_known_gt(f.offset, lu.max_offset) lu.max_offset = f.offset;
    if imm_known_lt(f.offset, lu.min_offset) lu.min_offset = f.offset;
}
lsr_sorted_key :: (f: *Lsr_Formula) -> [..] Scev_Id {
    key: [..] Scev_Id; key.allocator = temp;
    for f.base_regs array_add(*key, it);
    if f.scaled_reg != SCEV_NULL array_add(*key, f.scaled_reg);
    // insertion sort by id (only used for uniquifying)
    for i: 1..key.count-1 { j := i; while j > 0 && key[j] < key[j-1] { t := key[j]; key[j] = key[j-1]; key[j-1] = t; j -= 1; } }
    return key;
}
lsr_key_eq :: (a: [] Scev_Id, b: [] Scev_Id) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}
lu_has_formula_with_same_regs :: (lu: *Lsr_Use, f: *Lsr_Formula) -> bool {
    key := lsr_sorted_key(f);
    for lu.uniquifier if lsr_key_eq(it, key) return true;
    return false;
}
lu_not_selected_probability :: (lu: *Lsr_Use, reg: Scev_Id) -> float32 {
    n := 0;
    for * lu.formulae if lf_references_reg(it, reg) n += 1;
    return (cast(float32) (lu.formulae.count - n)) / cast(float32) lu.formulae.count;
}
lsr_set_insert :: (l: *[..] Scev_Id, v: Scev_Id) -> bool { for l.* if it == v return false; array_add(l, v); return true; }
lsr_set_contains :: (l: [] Scev_Id, v: Scev_Id) -> bool { for l if it == v return true; return false; }
// LSRUse::InsertFormula
lu_insert_formula :: (lu: *Lsr_Use, f: *Lsr_Formula, l: Loop_Id) -> bool {
    if lu.formulae.count && lu.rigid_formula return false;
    key := lsr_sorted_key(f);
    for lu.uniquifier if lsr_key_eq(it, key) return false;
    array_add(*lu.uniquifier, key);
    array_add(*lu.formulae, lf_copy(f));
    for f.base_regs lsr_set_insert(*lu.regs, it);
    if f.scaled_reg != SCEV_NULL lsr_set_insert(*lu.regs, f.scaled_reg);
    return true;
}
// LSRUse::DeleteFormula(F)
lu_delete_formula :: (lu: *Lsr_Use, idx: s64) {
    last := lu.formulae.count - 1;
    if idx != last { t := lu.formulae[idx]; lu.formulae[idx] = lu.formulae[last]; lu.formulae[last] = t; }
    lu.formulae.count -= 1;
}
// LSRUse::RecomputeRegs
lu_recompute_regs :: (lu: *Lsr_Use, lu_idx: s64, ru: *Lsr_Reg_Uses) {
    old := lu.regs;
    new_regs: [..] Scev_Id; new_regs.allocator = temp;
    lu.regs = new_regs;
    for * f: lu.formulae {
        if f.scaled_reg != SCEV_NULL lsr_set_insert(*lu.regs, f.scaled_reg);
        for f.base_regs lsr_set_insert(*lu.regs, it);
    }
    for s: old if !lsr_set_contains(lu.regs, s) ru_drop_register(ru, s, lu_idx);
}

// LSRFixup::isUseFullyOutsideLoop
lsr_fixup_is_use_fully_outside_loop :: (fx: *Lsr_Fixup, l: Loop_Id) -> bool {
    u := fx.user_inst;
    if inst_op(u) == .PHI {
        for k: 0..cast(s64) nops(u) - 1
            if phi_value(u, cast(u32) k) == fx.operand_val_to_replace && li_contains(se.li, l, phi_block(u, cast(u32) k)) return false;
        return true;
    }
    return !li_contains_inst(se.li, l, u);
}

// ---------------------------------------------------------------- TTI hooks (X86TTIImpl / X86TargetLowering)

lsr_tti: *Tti;
LSR_IID_PREFETCH :: #run iid_by_name("llvm.prefetch");
lsr_xl :: () -> *X86_Lowering { return *lsr_tti.xl; }

// TTI.isLegalAddressingMode(Ty, BaseGV, BaseOffset, HasBaseReg, Scale, AddrSpace, I, ScalableOffset)
lsr_is_legal_addressing_mode :: (ty: Type_Id, base_gv: Value_Id, offs: s64, has_base_reg: bool, scale: s64, as: u32, scalable_offs: s64) -> bool {
    if lsr_tti.kind != .X86 {
        // TargetTransformInfoImplBase: Guess that only reg and reg+reg addressing is allowed
        return base_gv == NONE && offs == 0 && (scale == 0 || scale == 1);
    }
    if scalable_offs != 0 return false;
    return x86_is_legal_addressing_mode(lsr_xl(), ty, base_gv, offs, has_base_reg, scale, as);
}
// isLegalICmpImmediate / isLegalAddImmediate (X86: isInt<32>)
lsr_is_legal_icmp_immediate :: (v: s64) -> bool {
    if lsr_tti.kind != .X86 return false;   // TargetTransformInfoImplBase
    return v >= -0x8000_0000 && v <= 0x7FFF_FFFF;
}
lsr_is_legal_add_immediate :: (v: s64) -> bool {
    if lsr_tti.kind != .X86 return false;
    return v >= -0x8000_0000 && v <= 0x7FFF_FFFF;
}
// X86TTIImpl::canMacroFuseCmp: hasMacroFusion() || hasBranchFusion()
lsr_can_macro_fuse_cmp :: () -> bool {
    if lsr_tti.kind != .X86 return false;
    return xs_has(lsr_xl(), X86FLD_HasMacroFusion) || xs_has(lsr_xl(), X86FLD_HasBranchFusion);
}
// X86TTIImpl::getScalingFactorCost -> (valid, cost)
lsr_scaling_factor_cost :: (ty: Type_Id, base_gv: Value_Id, offs: s64, has_base_reg: bool, scale: s64, as: u32) -> (bool, s64) {
    if lsr_tti.kind != .X86 {
        // TargetTransformInfoImplBase::getScalingFactorCost: 0 if legal
        if lsr_is_legal_addressing_mode(ty, base_gv, offs, has_base_reg, scale, as, 0) return true, 0;
        return false, 0;
    }
    if x86_is_legal_addressing_mode(lsr_xl(), ty, base_gv, offs, has_base_reg, scale, as) return true, ifx scale != 0 then cast(s64) 1 else 0;
    return false, 0;
}

// isAMCompletelyFolded(TTI, Kind, AccessTy, BaseGV, BaseOffset, HasBaseReg, Scale, Fixup)
lsr_is_am_completely_folded_kind :: (kind: Lsr_Kind, at: Lsr_Mem_Ty, base_gv: Value_Id, base_offset_in: Lsr_Imm, has_base_reg: bool, scale: s64) -> bool {
    base_offset := base_offset_in;
    if kind == {
        case .ADDRESS;
            fixed := ifx base_offset.scalable then 0 else base_offset.v;
            scal := ifx base_offset.scalable then base_offset.v else 0;
            return lsr_is_legal_addressing_mode(at.mem_ty, base_gv, fixed, has_base_reg, scale, at.as, scal);
        case .ICMP_ZERO;
            if base_gv != NONE return false;
            if scale != 0 && has_base_reg && imm_nz(base_offset) return false;
            if scale != 0 && scale != -1 return false;
            if imm_nz(base_offset) {
                if base_offset.scalable return false;
                if scale == 0 base_offset = imm_fixed(cast,no_check(s64) (0 - cast,no_check(u64) base_offset.v));
                return lsr_is_legal_icmp_immediate(base_offset.v);
            }
            return true;
        case .BASIC;
            return base_gv == NONE && scale == 0 && imm_is_zero(base_offset);
        case .SPECIAL;
            return base_gv == NONE && (scale == 0 || scale == -1) && imm_is_zero(base_offset);
    }
    return false;
}

// isAMCompletelyFolded(TTI, MinOffset, MaxOffset, Kind, AccessTy, BaseGV, BaseOffset, HasBaseReg, Scale)
lsr_is_am_completely_folded_range :: (min_in: Lsr_Imm, max_in: Lsr_Imm, kind: Lsr_Kind, at: Lsr_Mem_Ty, base_gv: Value_Id, base_offset: Lsr_Imm, has_base_reg: bool, scale: s64) -> bool {
    if imm_nz(base_offset) && (base_offset.scalable != min_in.scalable || base_offset.scalable != max_in.scalable) return false;
    base := base_offset.v; mn := min_in.v; mx := max_in.v;
    s1 := cast,no_check(s64) (cast,no_check(u64) base + cast,no_check(u64) mn);
    if (s1 > base) != (mn > 0) return false;
    min_o := Lsr_Imm.{s1, min_in.scalable};
    s2 := cast,no_check(s64) (cast,no_check(u64) base + cast,no_check(u64) mx);
    if (s2 > base) != (mx > 0) return false;
    max_o := Lsr_Imm.{s2, max_in.scalable};
    return lsr_is_am_completely_folded_kind(kind, at, base_gv, min_o, has_base_reg, scale) &&
           lsr_is_am_completely_folded_kind(kind, at, base_gv, max_o, has_base_reg, scale);
}
lsr_is_am_completely_folded_f :: (min_o: Lsr_Imm, max_o: Lsr_Imm, kind: Lsr_Kind, at: Lsr_Mem_Ty, f: *Lsr_Formula) -> bool {
    return lsr_is_am_completely_folded_range(min_o, max_o, kind, at, f.base_gv, f.base_offset, f.has_base_reg, f.scale);
}
// isLegalUse
lsr_is_legal_use :: (min_o: Lsr_Imm, max_o: Lsr_Imm, kind: Lsr_Kind, at: Lsr_Mem_Ty, base_gv: Value_Id, base_offset: Lsr_Imm, has_base_reg: bool, scale: s64) -> bool {
    return lsr_is_am_completely_folded_range(min_o, max_o, kind, at, base_gv, base_offset, has_base_reg, scale) ||
           (scale == 1 && lsr_is_am_completely_folded_range(min_o, max_o, kind, at, base_gv, base_offset, true, 0));
}
lsr_is_legal_use_f :: (min_o: Lsr_Imm, max_o: Lsr_Imm, kind: Lsr_Kind, at: Lsr_Mem_Ty, f: *Lsr_Formula) -> bool {
    return lsr_is_legal_use(min_o, max_o, kind, at, f.base_gv, f.base_offset, f.has_base_reg, f.scale);
}
// isLegalAddImmediate(TTI, Offset)
lsr_is_legal_add_imm :: (o: Lsr_Imm) -> bool {
    if o.scalable return false;   // isLegalAddScalableImmediate: false (no X86 override)
    return lsr_is_legal_add_immediate(o.v);
}
// isAMCompletelyFolded(TTI, LU, F) (TTI.LSRWithInstrQueries() is false)
lsr_is_am_completely_folded_lu :: (lu: *Lsr_Use, f: *Lsr_Formula) -> bool {
    return lsr_is_am_completely_folded_range(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, f.base_gv, f.base_offset, f.has_base_reg, f.scale);
}
// getScalingFactorCost(TTI, LU, F, L)
lsr_get_scaling_factor_cost :: (lu: *Lsr_Use, f: *Lsr_Formula) -> s64 {
    if f.scale == 0 return 0;
    if !lsr_is_am_completely_folded_f(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, f) return ifx f.scale != 1 then cast(s64) 1 else 0;
    if lu.kind == .ADDRESS {
        if f.base_offset.scalable fatal("loop-reduce: scalable offsets are not supported");
        fmin := imm_add(f.base_offset, lu.min_offset).v;
        fmax := imm_add(f.base_offset, lu.max_offset).v;
        ok1, c1 := lsr_scaling_factor_cost(lu.access_ty.mem_ty, f.base_gv, fmin, f.has_base_reg, f.scale, lu.access_ty.as);
        ok2, c2 := lsr_scaling_factor_cost(lu.access_ty.mem_ty, f.base_gv, fmax, f.has_base_reg, f.scale, lu.access_ty.as);
        if !ok1 || !ok2 fatal("loop-reduce: Legal addressing mode has an illegal cost!");
        return max(c1, c2);
    }
    return 0;
}

// isAlwaysFoldable(TTI, Kind, AccessTy, BaseGV, BaseOffset, HasBaseReg)
lsr_is_always_foldable :: (kind: Lsr_Kind, at: Lsr_Mem_Ty, base_gv: Value_Id, base_offset: Lsr_Imm, has_base_reg_in: bool) -> bool {
    has_base_reg := has_base_reg_in;
    if imm_is_zero(base_offset) && base_gv == NONE return true;
    scale: s64 = ifx kind == .ICMP_ZERO then -1 else 1;
    if !has_base_reg && scale == 1 { scale = 0; has_base_reg = true; }
    if has_base_reg && imm_nz(base_offset) && kind != .ICMP_ZERO && at.mem_ty != NONE && type_kind(at.mem_ty) == .SVECTOR && lsr_cl.drop_scaled_for_vscale scale = 0;
    return lsr_is_am_completely_folded_kind(kind, at, base_gv, base_offset, has_base_reg, scale);
}
// isAlwaysFoldable(TTI, SE, MinOffset, MaxOffset, Kind, AccessTy, S, HasBaseReg)
lsr_is_always_foldable_scev :: (min_o: Lsr_Imm, max_o: Lsr_Imm, kind: Lsr_Kind, at: Lsr_Mem_Ty, s: Scev_Id, has_base_reg: bool) -> bool {
    if sc_is_zero(s) return true;
    s_copy := s;
    base_offset := lsr_extract_immediate(*s_copy);
    base_gv := lsr_extract_symbol(*s_copy);
    if !sc_is_zero(s_copy) return false;
    if imm_is_zero(base_offset) && base_gv == NONE return true;
    if base_offset.scalable return false;
    scale: s64 = ifx kind == .ICMP_ZERO then -1 else 1;
    return lsr_is_am_completely_folded_range(min_o, max_o, kind, at, base_gv, base_offset, has_base_reg, scale);
}
