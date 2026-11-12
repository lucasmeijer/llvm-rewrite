// LoopStrengthReduce, part 4: port of llvm/lib/Transforms/Scalar/LoopStrengthReduce.cpp: formula generation
// (CollectSubexprs, GenerateReassociations, GenerateCombinations, GenerateSymbolicOffsets, GenerateConstantOffsets,
// GenerateICmpZeroScales, GenerateScales, GenerateTruncates, GenerateCrossUseConstantOffsets,
// GenerateAllReuseFormulae), filtering (FilterOutUndesirableDedicatedRegisters, the NarrowSearchSpace* heuristics)
// and the solver (SolveRecurse, Solve).

// CollectSubexprs: returns the remainder (SCEV_NULL when Ops is complete)
lsr_collect_subexprs :: (s: Scev_Id, c: Scev_Id, ops: *[..] Scev_Id, l: Loop_Id, depth: u32 = 0) -> Scev_Id {
    if depth >= 3 return s;
    k := sc_kind(s);
    if k == .ADD {
        for i: 0..cast(s64) sc_nops(s) - 1 {
            r := lsr_collect_subexprs(sc_op(s, cast(u32) i), c, ops, l, depth + 1);
            if r != SCEV_NULL array_add(ops, ifx c != SCEV_NULL then sc_get_mul2(c, r) else r);
        }
        return SCEV_NULL;
    }
    if k == .ADDREC && sc_is_affine(s) {
        start := sc_start(s);
        step := sc_op(s, 1);
        if sc_is_zero(start) return s;
        remainder := lsr_collect_subexprs(start, c, ops, l, depth + 1);
        if remainder != SCEV_NULL && (sc_loop(s) == l || sc_kind(remainder) != .ADDREC) {
            array_add(ops, ifx c != SCEV_NULL then sc_get_mul2(c, remainder) else remainder);
            remainder = SCEV_NULL;
        }
        if remainder != start {
            if remainder == SCEV_NULL remainder = sc_get_constant_t(sc_type(s), 0);
            return sc_get_add_rec(remainder, step, sc_loop(s), SF_ANY);
        }
    } else if k == .MUL && sc_nops(s) == 2 && sc_is_const(sc_op(s, 0)) {
        op0 := sc_op(s, 0);
        cc := ifx c != SCEV_NULL then sc_get_mul2(c, op0) else op0;
        remainder := lsr_collect_subexprs(sc_op(s, 1), cc, ops, l, depth + 1);
        if remainder != SCEV_NULL array_add(ops, sc_get_mul2(cc, remainder));
        return SCEV_NULL;
    }
    return s;
}

lsr_log2_32 :: (v: u64) -> u32 { if v == 0 return 0xFFFF_FFFF; r: u32 = 0; x := v; while x > 1 { x >>= 1; r += 1; } return r; }

// GenerateReassociationsImpl
lsr_generate_reassociations_impl :: (lu_idx: s64, base: *Lsr_Formula, depth: u32, idx: s64, is_scaled_reg: bool) {
    base_reg := ifx is_scaled_reg then base.scaled_reg else base.base_regs[idx];
    add_ops: [..] Scev_Id; add_ops.allocator = temp;
    remainder := lsr_collect_subexprs(base_reg, SCEV_NULL, *add_ops, lsr.l);
    if remainder != SCEV_NULL array_add(*add_ops, remainder);
    if add_ops.count == 1 return;
    for j: 0..add_ops.count-1 {
        lu := *lsr.uses[lu_idx];
        jv := add_ops[j];
        if sc_kind(jv) == .UNKNOWN && !sc_is_loop_invariant(jv, lsr.l) continue;
        if lsr_is_always_foldable_scev(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, jv, lf_num_regs(base) > 1) continue;
        inner: [..] Scev_Id; inner.allocator = temp;
        for add_ops if it_index != j array_add(*inner, it);
        if inner.count == 1 && lsr_is_always_foldable_scev(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, inner[0], lf_num_regs(base) > 1) continue;
        inner_sum := sc_get_add(*inner);
        if sc_is_zero(inner_sum) continue;
        f := lf_copy(base);
        if imm_nz(f.unfolded_offset) && f.unfolded_offset.scalable continue;
        if sc_is_const(inner_sum) && sc_type_bits(sc_type(inner_sum)) <= 64 &&
           lsr_is_legal_add_immediate(cast,no_check(s64) (cast,no_check(u64) f.unfolded_offset.v + ap_zext_value(sc_ap(inner_sum)))) {
            f.unfolded_offset = imm_fixed(cast,no_check(s64) (cast,no_check(u64) f.unfolded_offset.v + ap_zext_value(sc_ap(inner_sum))));
            if is_scaled_reg { f.scaled_reg = SCEV_NULL; f.scale = 0; }
            else array_ordered_remove_by_index(*f.base_regs, idx);
        } else if is_scaled_reg f.scaled_reg = inner_sum;
        else f.base_regs[idx] = inner_sum;
        if sc_is_const(jv) && sc_type_bits(sc_type(jv)) <= 64 &&
           lsr_is_legal_add_immediate(cast,no_check(s64) (cast,no_check(u64) f.unfolded_offset.v + ap_zext_value(sc_ap(jv))))
            f.unfolded_offset = imm_fixed(cast,no_check(s64) (cast,no_check(u64) f.unfolded_offset.v + ap_zext_value(sc_ap(jv))));
        else array_add(*f.base_regs, jv);
        lf_canonicalize(*f, lsr.l);
        if lsr_insert_formula(lu, lu_idx, *f) {
            lu = *lsr.uses[lu_idx];
            nb := lf_copy(*lu.formulae[lu.formulae.count - 1]);
            lsr_generate_reassociations(lu_idx, *nb, depth + 1 + (lsr_log2_32(cast(u64) add_ops.count) >> 2));
        }
    }
}
// GenerateReassociations
lsr_generate_reassociations :: (lu_idx: s64, base: *Lsr_Formula, depth: u32 = 0) {
    if depth >= 3 return;
    for i: 0..base.base_regs.count-1 lsr_generate_reassociations_impl(lu_idx, base, depth, i, false);
    if base.scale == 1 lsr_generate_reassociations_impl(lu_idx, base, depth, -1, true);
}

// GenerateCombinations
lsr_generate_combinations :: (lu_idx: s64, base_in: *Lsr_Formula) {
    base := lf_copy(base_in);
    if base.base_regs.count + (ifx base.scale == 1 then 1 else 0) + (ifx imm_nz(base.unfolded_offset) then 1 else 0) <= 1 return;
    lf_unscale(*base);
    ops: [..] Scev_Id; ops.allocator = temp;
    new_base := lf_copy(*base);
    new_base.base_regs.count = 0;
    combined_ty: Type_Id = NONE;
    header := li_header(lsr.li, lsr.l);
    for br: base.base_regs {
        if sc_properly_dominates(br, header) && !sc_has_computable_loop_evolution(br, lsr.l) {
            if combined_ty == NONE combined_ty = sc_effective_type(sc_type(br));
            array_add(*ops, br);
        } else array_add(*new_base.base_regs, br);
    }
    if ops.count == 0 return;
    generate_formula :: (lu_idx: s64, nb: *Lsr_Formula, sum: Scev_Id) {
        f := lf_copy(nb);
        if sc_is_zero(sum) return;
        array_add(*f.base_regs, sum);
        lf_canonicalize(*f, lsr.l);
        lsr_insert_formula(*lsr.uses[lu_idx], lu_idx, *f);
    }
    if ops.count > 1 {
        ops_copy: [..] Scev_Id; ops_copy.allocator = temp;
        for ops array_add(*ops_copy, it);
        generate_formula(lu_idx, *new_base, sc_get_add(*ops_copy));
    }
    if imm_nz(new_base.unfolded_offset) && !new_base.unfolded_offset.scalable {
        array_add(*ops, sc_get_constant_t(combined_ty, cast,no_check(u64) new_base.unfolded_offset.v, true));
        new_base.unfolded_offset = imm_fixed(0);
        generate_formula(lu_idx, *new_base, sc_get_add(*ops));
    }
}

// GenerateSymbolicOffsetsImpl / GenerateSymbolicOffsets
lsr_generate_symbolic_offsets_impl :: (lu_idx: s64, base: *Lsr_Formula, idx: s64, is_scaled_reg: bool) {
    g := ifx is_scaled_reg then base.scaled_reg else base.base_regs[idx];
    gv := lsr_extract_symbol(*g);
    if sc_is_zero(g) || gv == NONE return;
    f := lf_copy(base);
    f.base_gv = gv;
    lu := *lsr.uses[lu_idx];
    if !lsr_is_legal_use_f(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, *f) return;
    if is_scaled_reg f.scaled_reg = g; else f.base_regs[idx] = g;
    lsr_insert_formula(lu, lu_idx, *f);
}
lsr_generate_symbolic_offsets :: (lu_idx: s64, base: *Lsr_Formula) {
    if base.base_gv != NONE return;
    for i: 0..base.base_regs.count-1 lsr_generate_symbolic_offsets_impl(lu_idx, base, i, false);
    if base.scale == 1 lsr_generate_symbolic_offsets_impl(lu_idx, base, -1, true);
}

// GenerateConstantOffsetsImpl / GenerateConstantOffsets
lsr_generate_constant_offsets_impl :: (lu_idx: s64, base: *Lsr_Formula, worklist: [] Lsr_Imm, idx: s64, is_scaled_reg: bool) {
    generate_offset :: (lu_idx: s64, base: *Lsr_Formula, g: Scev_Id, offset: Lsr_Imm, idx: s64, is_scaled_reg: bool) {
        f := lf_copy(base);
        if !imm_compatible(base.base_offset, offset) return;
        f.base_offset = imm_sub_unsigned(base.base_offset, offset);
        lu := *lsr.uses[lu_idx];
        if lsr_is_legal_use_f(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, *f) {
            new_offset := imm_scev(offset, sc_type(g));
            new_g := sc_get_add2(new_offset, g);
            if sc_is_zero(new_g) {
                if is_scaled_reg { f.scale = 0; f.scaled_reg = SCEV_NULL; }
                else lf_delete_base_reg(*f, idx);
                lf_canonicalize(*f, lsr.l);
            } else if is_scaled_reg f.scaled_reg = new_g;
            else f.base_regs[idx] = new_g;
            lsr_insert_formula(lu, lu_idx, *f);
        }
    }
    g := ifx is_scaled_reg then base.scaled_reg else base.base_regs[idx];
    // AMK_PreIndexed: never on X86
    for worklist generate_offset(lu_idx, base, g, it, idx, is_scaled_reg);
    imm := lsr_extract_immediate(*g);
    if sc_is_zero(g) || imm_is_zero(imm) || !imm_compatible(base.base_offset, imm) return;
    f := lf_copy(base);
    f.base_offset = imm_add_unsigned(f.base_offset, imm);
    lu := *lsr.uses[lu_idx];
    if !lsr_is_legal_use_f(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, *f) return;
    if is_scaled_reg f.scaled_reg = g;
    else {
        f.base_regs[idx] = g;
        lf_canonicalize(*f, lsr.l);
    }
    lsr_insert_formula(lu, lu_idx, *f);
}
lsr_generate_constant_offsets :: (lu_idx: s64, base: *Lsr_Formula) {
    lu := *lsr.uses[lu_idx];
    worklist: [..] Lsr_Imm; worklist.allocator = temp;
    array_add(*worklist, lu.min_offset);
    if !imm_eq(lu.max_offset, lu.min_offset) array_add(*worklist, lu.max_offset);
    for i: 0..base.base_regs.count-1 lsr_generate_constant_offsets_impl(lu_idx, base, worklist, i, false);
    if base.scale == 1 lsr_generate_constant_offsets_impl(lu_idx, base, worklist, -1, true);
}

// ConstantInt::isValueValidForType(Ty, int64_t)
lsr_value_valid_for_type :: (ty: Type_Id, v: s64) -> bool {
    bits := type_bits(ty);
    if bits == 1 return v == 0 || v == 1 || v == -1;
    if bits >= 64 return true;
    lim := (cast(s64) 1) << (bits - 1);
    return v >= -lim && v < lim;
}

// GenerateICmpZeroScales
lsr_generate_icmp_zero_scales :: (lu_idx: s64, base: *Lsr_Formula) {
    lu := *lsr.uses[lu_idx];
    if lu.kind != .ICMP_ZERO return;
    int_ty := lf_type(base);
    if int_ty == NONE return;
    if sc_type_bits(int_ty) > 64 return;
    if !imm_eq(lu.min_offset, lu.max_offset) return;
    if base.scaled_reg != SCEV_NULL && type_kind(sc_type(base.scaled_reg)) == .PTR return;
    for base.base_regs if type_kind(sc_type(it)) == .PTR return;
    is_ptr := type_kind(int_ty) == .PTR;
    for factor: lsr.factors {
        lu = *lsr.uses[lu_idx];
        if !lsr_value_valid_for_type(int_ty, factor) continue;
        if imm_is_min(base.base_offset) && factor == -1 continue;
        if imm_nz(base.base_offset) && base.base_offset.scalable continue;
        new_base_offset := imm_mul_unsigned(base.base_offset, factor);
        if new_base_offset.v / factor != base.base_offset.v continue;
        if !is_ptr && !lsr_value_valid_for_type(int_ty, new_base_offset.v) continue;
        offset := lu.min_offset;
        if imm_is_min(offset) && factor == -1 continue;
        offset = imm_mul_unsigned(offset, factor);
        if offset.v / factor != lu.min_offset.v continue;
        if !is_ptr && !lsr_value_valid_for_type(int_ty, offset.v) continue;
        f := lf_copy(base);
        f.base_offset = new_base_offset;
        if !lsr_is_legal_use_f(offset, offset, lu.kind, lu.access_ty, *f) continue;
        f.base_offset = imm_sub_unsigned(imm_add_unsigned(f.base_offset, offset), lu.min_offset);
        factor_s := sc_get_constant_t(int_ty, cast,no_check(u64) factor, true);
        ok := true;
        for i: 0..f.base_regs.count-1 {
            f.base_regs[i] = sc_get_mul2(f.base_regs[i], factor_s);
            if lsr_get_exact_sdiv(f.base_regs[i], factor_s) != base.base_regs[i] { ok = false; break; }
        }
        if !ok continue;
        if f.scaled_reg != SCEV_NULL {
            f.scaled_reg = sc_get_mul2(f.scaled_reg, factor_s);
            if lsr_get_exact_sdiv(f.scaled_reg, factor_s) != base.scaled_reg continue;
        }
        if imm_nz(f.unfolded_offset) {
            if imm_is_min(f.unfolded_offset) && factor == -1 continue;
            f.unfolded_offset = imm_mul_unsigned(f.unfolded_offset, factor);
            if f.unfolded_offset.v / factor != base.unfolded_offset.v continue;
            if !is_ptr && !lsr_value_valid_for_type(int_ty, f.unfolded_offset.v) continue;
        }
        lsr_insert_formula(lu, lu_idx, *f);
    }
}

// GenerateScales
lsr_generate_scales :: (lu_idx: s64, base_in: *Lsr_Formula) {
    base := lf_copy(base_in);
    int_ty := lf_type(*base);
    if int_ty == NONE return;
    if base.scale != 0 && !lf_unscale(*base) return;
    for factor: lsr.factors {
        lu := *lsr.uses[lu_idx];
        base.scale = factor;
        base.has_base_reg = base.base_regs.count > 1;
        if !lsr_is_legal_use_f(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, *base) {
            if lu.kind == .BASIC && lsr_is_legal_use_f(lu.min_offset, lu.max_offset, .SPECIAL, lu.access_ty, *base) && lu.all_fixups_outside_loop
                lu.kind = .SPECIAL;
            else continue;
        }
        if lu.kind == .ICMP_ZERO && !base.has_base_reg && imm_is_zero(base.base_offset) && base.base_gv == NONE continue;
        for i: 0..base.base_regs.count-1 {
            ar := base.base_regs[i];
            if sc_kind(ar) == .ADDREC && (sc_loop(ar) == lsr.l || lu.all_fixups_outside_loop) {
                factor_s := sc_get_constant_t(int_ty, cast,no_check(u64) factor, true);
                if sc_is_zero(factor_s) continue;
                quotient := lsr_get_exact_sdiv(ar, factor_s, true);
                if quotient != SCEV_NULL && !sc_is_zero(quotient) {
                    f := lf_copy(*base);
                    f.scaled_reg = quotient;
                    lf_delete_base_reg(*f, i);
                    if f.scale == 1 && (f.base_regs.count == 0 || (sc_loop(ar) != lsr.l && lu.all_fixups_outside_loop)) continue;
                    if f.scale == 1 && lu.all_fixups_outside_loop lf_canonicalize(*f, lsr.l);
                    lsr_insert_formula(lu, lu_idx, *f);
                }
            }
        }
    }
}

// getAnyExtendConsideringPostIncUses
lsr_get_any_extend_considering_post_inc_uses :: (loops: [] *[..] Loop_Id, expr: Scev_Id, to_ty: Type_Id) -> Scev_Id {
    result: Scev_Id = SCEV_NULL;
    for l: loops {
        denorm := denormalize_for_post_inc_use(expr, l);
        new_denorm := sc_get_any_extend(denorm, to_ty);
        nw := lsr_normalize_for_post_inc_use(new_denorm, l);
        if nw == SCEV_NULL || (result != SCEV_NULL && nw != result) return SCEV_NULL;
        result = nw;
    }
    return result;
}

// GenerateTruncates
lsr_generate_truncates :: (lu_idx: s64, base: *Lsr_Formula) {
    if base.base_gv != NONE return;
    dst_ty := lf_type(base);
    if dst_ty == NONE return;
    if type_kind(dst_ty) == .PTR return;
    if base.scaled_reg != SCEV_NULL && type_kind(sc_type(base.scaled_reg)) == .PTR return;
    for base.base_regs if type_kind(sc_type(it)) == .PTR return;
    lu := *lsr.uses[lu_idx];
    loops: [..] *[..] Loop_Id; loops.allocator = temp;
    for * lf: lu.fixups array_add(*loops, *lf.post_inc_loops);
    for src_ty: lsr.types {
        if src_ty != dst_ty && tti_is_truncate_free(lsr_tti, src_ty, dst_ty) {
            f := lf_copy(base);
            if f.scaled_reg != SCEV_NULL {
                nsr := lsr_get_any_extend_considering_post_inc_uses(loops, f.scaled_reg, src_ty);
                if nsr == SCEV_NULL || sc_is_zero(nsr) continue;
                f.scaled_reg = nsr;
            }
            has_zero := false;
            for * br: f.base_regs {
                nbr := lsr_get_any_extend_considering_post_inc_uses(loops, br.*, src_ty);
                if nbr == SCEV_NULL || sc_is_zero(nbr) { has_zero = true; break; }
                br.* = nbr;
            }
            if has_zero continue;
            if !lf_has_regs_used_by_uses_other_than(*f, lu_idx, *lsr.reg_uses) continue;
            lf_canonicalize(*f, lsr.l);
            lsr_insert_formula(lu, lu_idx, *f);
        }
    }
}

// KeyOrderTargetImmediate
imm_key_less :: (a: Lsr_Imm, b: Lsr_Imm) -> bool {
    if a.scalable && !b.scalable return false;
    if !a.scalable && b.scalable return true;
    return a.v < b.v;
}

// GenerateCrossUseConstantOffsets
lsr_generate_cross_use_constant_offsets :: () {
    Imm_Entry :: struct { imm: Lsr_Imm; reg: Scev_Id; }
    Group :: struct { reg: Scev_Id; imms: [..] Imm_Entry; used_by: [..] bool; }   // ImmMapTy (sorted), UsedByIndicesMap
    groups: [..] Group; groups.allocator = temp;
    group_of: Table(Scev_Id, s64); group_of.allocator = temp;
    for use: lsr.reg_uses.sequence {
        reg := use;
        imm := lsr_extract_immediate(*reg);
        found, gi := table_find(*group_of, reg);
        if !found {
            gi = groups.count;
            g: Group; g.reg = reg; g.imms.allocator = temp; g.used_by.allocator = temp;
            array_add(*groups, g);
            table_set(*group_of, reg, gi);
        }
        g := *groups[gi];
        // std::map::insert: keep the first entry for an equal key
        pos := 0;
        dup := false;
        while pos < g.imms.count {
            if !imm_key_less(g.imms[pos].imm, imm) && !imm_key_less(imm, g.imms[pos].imm) { dup = true; break; }
            if imm_key_less(imm, g.imms[pos].imm) break;
            pos += 1;
        }
        if !dup array_insert_at(*g.imms, .{imm, use}, pos);
        ub := ru_used_by(*lsr.reg_uses, use);
        while g.used_by.count < ub.count array_add(*g.used_by, false);
        for ub if it g.used_by[it_index] = true;
    }
    Work_Item :: struct { lu_idx: s64; imm: Lsr_Imm; orig_reg: Scev_Id; }
    work_items: [..] Work_Item; work_items.allocator = temp;
    Uniq :: struct { lu: s64; imm: Lsr_Imm; }
    unique_items: [..] Uniq; unique_items.allocator = temp;
    for * g: groups {
        imms := g.imms;
        if imms.count == 1 continue;
        for j: 0..imms.count-1 {
            orig_reg := imms[j].reg;
            j_imm := imms[j].imm;
            used_by := ru_used_by(*lsr.reg_uses, orig_reg);
            cnt := 0;
            for g.used_by if it cnt += 1;
            if !sc_is_const(orig_reg) && cnt == 1 continue;
            first := imms[0].imm;
            last := imms[imms.count - 1].imm;
            if !imm_compatible(first, last) continue;
            scalable := first.scalable || last.scalable;
            fi := first.v; li := last.v;
            avg := (fi & li) + ((fi ^ li) >> 1);   // >> on s64 is an arithmetic shift
            sign_bit := (cast,no_check(u64) avg) >> 63;
            avg = avg + ((fi ^ li) & cast,no_check(s64) sign_bit);
            // lower_bound(Immediate::get(Avg, Scalable))
            target := Lsr_Imm.{avg, scalable};
            lb := 0;
            while lb < imms.count && imm_key_less(imms[lb].imm, target) lb += 1;
            others := s64.[0, imms.count - 1, lb];
            for m: others {
                if m == j || m == imms.count continue;
                if !imm_compatible(j_imm, imms[m].imm) continue;
                imm := imm_sub_unsigned(j_imm, imms[m].imm);
                for set, lu_idx: used_by {
                    if !set continue;
                    dup := false;
                    for unique_items if it.lu == lu_idx && imm_eq(it.imm, imm) { dup = true; break; }
                    if dup continue;
                    array_add(*unique_items, .{lu_idx, imm});
                    array_add(*work_items, .{lu_idx, imm, orig_reg});
                }
            }
        }
    }
    if lsr_debug_enabled() {
        sb: String_Builder; sb.allocator = temp;
        for * g: groups { append(*sb, "group "); sc_print(*sb, g.reg); for g.imms { print_to_builder(*sb, " [%: ", it.imm.v); sc_print(*sb, it.reg); append(*sb, "]"); } append(*sb, "\n"); }
        for wi: work_items { print_to_builder(*sb, "work use % imm % reg ", wi.lu_idx, wi.imm.v); sc_print(*sb, wi.orig_reg); append(*sb, "\n"); }
        write_string(builder_to_string(*sb,, temp), to_standard_error = true);
    }
    for wi: work_items {
        lu_idx := wi.lu_idx;
        imm := wi.imm;
        orig_reg := wi.orig_reg;
        int_ty := sc_effective_type(sc_type(orig_reg));
        neg_imm_s := imm_neg_scev(imm, int_ty);
        bit_width := sc_type_bits(int_ty);
        nf := lsr.uses[lu_idx].formulae.count;
        for li: 0..nf-1 {
            lu := *lsr.uses[lu_idx];
            f := lf_copy(*lu.formulae[li]);
            lf_unscale(*f);
            if f.scaled_reg == orig_reg {
                if !imm_compatible(f.base_offset, imm) continue;
                offset := imm_add_unsigned(f.base_offset, imm_mul_unsigned(imm, f.scale));
                s := imm_neg_scev(offset, int_ty);
                if lf_references_reg(*f, s) continue;
                new_f := lf_copy(*f);
                new_f.base_offset = offset;
                if !lsr_is_legal_use_f(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, *new_f) continue;
                new_f.scaled_reg = sc_get_add2(neg_imm_s, new_f.scaled_reg);
                if sc_is_const(new_f.scaled_reg) {
                    c := sc_ap(new_f.scaled_reg);
                    if imm_nz(new_f.base_offset) && new_f.base_offset.scalable continue;
                    prod := ap_mul(ap_abs(c), ap_from_u64(bit_width, cast,no_check(u64) f.scale));
                    bo := new_f.base_offset.v;
                    abs_bo := cast,no_check(u64) (ifx bo < 0 then -bo else bo);
                    if ap_is_negative(c) != (bo < 0) && ap_active_bits(prod) <= 64 && ap_zext_value(prod) <= abs_bo continue;
                }
                lf_canonicalize(*new_f, lsr.l);
                lsr_insert_formula(lu, lu_idx, *new_f);
            } else {
                for n: 0..f.base_regs.count-1 {
                    base_reg := f.base_regs[n];
                    if base_reg != orig_reg continue;
                    new_f := lf_copy(*f);
                    if !imm_compatible(new_f.base_offset, imm) || !imm_compatible(new_f.unfolded_offset, imm) ||
                       !imm_compatible(new_f.base_offset, new_f.unfolded_offset) continue;
                    new_f.base_offset = imm_add_unsigned(new_f.base_offset, imm);
                    if !lsr_is_legal_use_f(lu.min_offset, lu.max_offset, lu.kind, lu.access_ty, *new_f) {
                        new_unfolded := imm_add_unsigned(new_f.unfolded_offset, imm);
                        if !lsr_is_legal_add_imm(new_unfolded) continue;
                        new_f = lf_copy(*f);
                        new_f.unfolded_offset = new_unfolded;
                    }
                    new_f.base_regs[n] = sc_get_add2(neg_imm_s, base_reg);
                    skip := false;
                    for new_reg: new_f.base_regs {
                        if sc_is_const(new_reg) {
                            if imm_nz(new_f.base_offset) && new_f.base_offset.scalable { skip = true; break; }
                            bo := new_f.base_offset.v;
                            sum := ap_add(sc_ap(new_reg), ap_from_u64(sc_ap(new_reg).bits, cast,no_check(u64) bo));
                            abs_bo := ifx bo < 0 then -bo else bo;
                            if ap_slt_s64(ap_abs(sum), abs_bo) && ap_ctz(sum) >= lsr_ctz64(cast,no_check(u64) bo) { skip = true; break; }
                        }
                    }
                    if skip continue;
                    lf_canonicalize(*new_f, lsr.l);
                    lsr_insert_formula(lu, lu_idx, *new_f);
                    break;
                }
            }
        }
    }
}
lsr_ctz64 :: (v: u64) -> u32 { if v == 0 return 64; n: u32 = 0; x := v; while (x & 1) == 0 { x >>= 1; n += 1; } return n; }

// GenerateAllReuseFormulae
lsr_generate_all_reuse_formulae :: () {
    num_uses := lsr.uses.count;
    for lu_idx: 0..num_uses-1 {
        i := 0; nf := lsr.uses[lu_idx].formulae.count; while i < nf { b := lf_copy(*lsr.uses[lu_idx].formulae[i]); lsr_generate_reassociations(lu_idx, *b); i += 1; }
        i = 0; nf = lsr.uses[lu_idx].formulae.count; while i < nf { b := lf_copy(*lsr.uses[lu_idx].formulae[i]); lsr_generate_combinations(lu_idx, *b); i += 1; }
    }
    for lu_idx: 0..num_uses-1 {
        i := 0; nf := lsr.uses[lu_idx].formulae.count; while i < nf { b := lf_copy(*lsr.uses[lu_idx].formulae[i]); lsr_generate_symbolic_offsets(lu_idx, *b); i += 1; }
        i = 0; nf = lsr.uses[lu_idx].formulae.count; while i < nf { b := lf_copy(*lsr.uses[lu_idx].formulae[i]); lsr_generate_constant_offsets(lu_idx, *b); i += 1; }
        i = 0; nf = lsr.uses[lu_idx].formulae.count; while i < nf { b := lf_copy(*lsr.uses[lu_idx].formulae[i]); lsr_generate_icmp_zero_scales(lu_idx, *b); i += 1; }
        i = 0; nf = lsr.uses[lu_idx].formulae.count; while i < nf { b := lf_copy(*lsr.uses[lu_idx].formulae[i]); lsr_generate_scales(lu_idx, *b); i += 1; }
    }
    for lu_idx: 0..num_uses-1 {
        i := 0; nf := lsr.uses[lu_idx].formulae.count; while i < nf { b := lf_copy(*lsr.uses[lu_idx].formulae[i]); lsr_generate_truncates(lu_idx, *b); i += 1; }
    }
    lsr_generate_cross_use_constant_offsets();
}

// FilterOutUndesirableDedicatedRegisters
lsr_filter_out_undesirable_dedicated_registers :: () {
    visited_regs: Table(Scev_Id, bool); visited_regs.allocator = temp;
    regs: [..] Scev_Id; regs.allocator = temp;
    loser_regs: [..] Scev_Id; loser_regs.allocator = temp;
    Best :: struct { key: [..] Scev_Id; idx: s64; }
    for lu_idx: 0..lsr.uses.count-1 {
        lu := *lsr.uses[lu_idx];
        best_formulae: [..] Best; best_formulae.allocator = temp;
        any := false;
        fidx := 0;
        num_forms := lu.formulae.count;
        while fidx != num_forms {
            f := *lu.formulae[fidx];
            cost_f: Lsr_Cost;
            regs.count = 0;
            cost_rate_formula(*cost_f, f, *regs, *visited_regs, lu, *loser_regs);
            delete := false;
            if cost_is_loser(*cost_f) delete = true;
            else {
                key: [..] Scev_Id; key.allocator = temp;
                for f.base_regs if ru_is_reg_used_by_uses_other_than(*lsr.reg_uses, it, lu_idx) array_add(*key, it);
                if f.scaled_reg != SCEV_NULL && ru_is_reg_used_by_uses_other_than(*lsr.reg_uses, f.scaled_reg, lu_idx) array_add(*key, f.scaled_reg);
                for i: 1..key.count-1 { j := i; while j > 0 && key[j] < key[j-1] { t := key[j]; key[j] = key[j-1]; key[j-1] = t; j -= 1; } }
                found := -1;
                for best_formulae if lsr_key_eq(it.key, key) { found = it.idx; break; }
                if found < 0 {
                    array_add(*best_formulae, .{key, fidx});
                } else {
                    best := *lu.formulae[found];
                    cost_best: Lsr_Cost;
                    regs.count = 0;
                    cost_rate_formula(*cost_best, best, *regs, *visited_regs, lu);
                    if cost_is_less(*cost_f, *cost_best) { t := f.*; f.* = best.*; best.* = t; }
                    delete = true;
                }
            }
            if delete {
                lu_delete_formula(lu, fidx);
                num_forms -= 1;
                any = true;
                continue;
            }
            fidx += 1;
        }
        if any lu_recompute_regs(lu, lu_idx, *lsr.reg_uses);
    }
}

// EstimateSearchSpaceComplexity
lsr_estimate_search_space_complexity :: () -> u64 {
    power: u64 = 1;
    for * lu: lsr.uses {
        fsize := cast(u64) lu.formulae.count;
        if fsize >= lsr_cl.complexity_limit { power = lsr_cl.complexity_limit; break; }
        power *= fsize;
        if power >= lsr_cl.complexity_limit break;
    }
    return power;
}

// NarrowSearchSpaceByDetectingSupersets
lsr_narrow_by_detecting_supersets :: () {
    if lsr_estimate_search_space_complexity() < lsr_cl.complexity_limit return;
    for lu_idx: 0..lsr.uses.count-1 {
        lu := *lsr.uses[lu_idx];
        any := false;
        i := 0; e := lu.formulae.count;
        while i != e {
            f := *lu.formulae[i];
            deleted := false;
            if !(imm_nz(f.base_offset) && f.base_offset.scalable) {
                for r, ri: f.base_regs {
                    if sc_is_const(r) {
                        new_f := lf_copy(f);
                        new_f.base_offset = imm_fixed(cast,no_check(s64) (cast,no_check(u64) new_f.base_offset.v + cast,no_check(u64) ap_sext_value(sc_ap(r))));
                        array_ordered_remove_by_index(*new_f.base_regs, ri);
                        if lu_has_formula_with_same_regs(lu, *new_f) {
                            lu_delete_formula(lu, i);
                            e -= 1; any = true; deleted = true;
                            break;
                        }
                    } else if sc_kind(r) == .UNKNOWN && is_global_value(vkind(sc_value(r))) && f.base_gv == NONE {
                        new_f := lf_copy(f);
                        new_f.base_gv = sc_value(r);
                        array_ordered_remove_by_index(*new_f.base_regs, ri);
                        if lu_has_formula_with_same_regs(lu, *new_f) {
                            lu_delete_formula(lu, i);
                            e -= 1; any = true; deleted = true;
                            break;
                        }
                    }
                }
            }
            if !deleted i += 1;
        }
        if any lu_recompute_regs(lu, lu_idx, *lsr.reg_uses);
    }
}

// NarrowSearchSpaceByCollapsingUnrolledCode
lsr_narrow_by_collapsing_unrolled_code :: () {
    if lsr_estimate_search_space_complexity() < lsr_cl.complexity_limit return;
    lu_idx := 0;
    num_uses := lsr.uses.count;
    while lu_idx != num_uses {
        lu := *lsr.uses[lu_idx];
        deleted_use := false;
        for * f: lu.formulae {
            if imm_is_zero(f.base_offset) || (f.scale != 0 && f.scale != 1) continue;
            that := lsr_find_use_with_similar_formula(f, lu_idx);
            if that < 0 continue;
            lu_that := *lsr.uses[that];
            if !lsr_reconcile_new_offset(lu_that, f.base_offset, false, lu.kind, lu.access_ty) continue;
            lu_that.all_fixups_outside_loop &= lu.all_fixups_outside_loop;
            lu_that.all_fixups_unconditional &= lu.all_fixups_unconditional;
            for * fx: lu.fixups {
                fx.offset = imm_add(fx.offset, f.base_offset);
                lu_push_fixup(lu_that, fx.*);
            }
            any := false;
            i := 0; e := lu_that.formulae.count;
            while i != e {
                if !lsr_is_legal_use_f(lu_that.min_offset, lu_that.max_offset, lu_that.kind, lu_that.access_ty, *lu_that.formulae[i]) {
                    lu_delete_formula(lu_that, i);
                    e -= 1; any = true;
                    continue;
                }
                i += 1;
            }
            if any lu_recompute_regs(lu_that, that, *lsr.reg_uses);
            lsr_delete_use(lu_idx);
            num_uses -= 1;
            deleted_use = true;
            break;
        }
        if !deleted_use lu_idx += 1;
    }
}

// NarrowSearchSpaceByFilterFormulaWithSameScaledReg
lsr_narrow_by_filter_formula_with_same_scaled_reg :: () {
    if lsr_estimate_search_space_complexity() < lsr_cl.complexity_limit return;
    visited_regs: Table(Scev_Id, bool); visited_regs.allocator = temp;
    regs: [..] Scev_Id; regs.allocator = temp;
    num_uses := lsr.uses.count;
    Best :: struct { reg: Scev_Id; scale: s64; idx: s64; }
    for lu_idx: 0..num_uses-1 {
        lu := *lsr.uses[lu_idx];
        is_better_than :: (fa: *Lsr_Formula, fb: *Lsr_Formula, lu: *Lsr_Use, num_uses: s64, regs: *[..] Scev_Id, visited: *Table(Scev_Id, bool)) -> bool {
            count_bits :: (b: [] bool) -> s64 { n := 0; for b if it n += 1; return n; }
            fa_num := 0; for fa.base_regs fa_num += num_uses - count_bits(ru_used_by(*lsr.reg_uses, it)) + 1;
            fb_num := 0; for fb.base_regs fb_num += num_uses - count_bits(ru_used_by(*lsr.reg_uses, it)) + 1;
            if fa_num != fb_num return fa_num < fb_num;
            ca: Lsr_Cost; cb: Lsr_Cost;
            regs.count = 0;
            cost_rate_formula(*ca, fa, regs, visited, lu);
            regs.count = 0;
            cost_rate_formula(*cb, fb, regs, visited, lu);
            return cost_is_less(*ca, *cb);
        }
        best_formulae: [..] Best; best_formulae.allocator = temp;
        any := false;
        fidx := 0; num_forms := lu.formulae.count;
        while fidx != num_forms {
            f := *lu.formulae[fidx];
            if f.scaled_reg == SCEV_NULL { fidx += 1; continue; }
            found := -1;
            for best_formulae if it.reg == f.scaled_reg && it.scale == f.scale { found = it.idx; break; }
            if found < 0 { array_add(*best_formulae, .{f.scaled_reg, f.scale, fidx}); fidx += 1; continue; }
            best := *lu.formulae[found];
            if is_better_than(f, best, lu, num_uses, *regs, *visited_regs) { t := f.*; f.* = best.*; best.* = t; }
            lu_delete_formula(lu, fidx);
            num_forms -= 1;
            any = true;
        }
        if any lu_recompute_regs(lu, lu_idx, *lsr.reg_uses);
    }
}

// NarrowSearchSpaceByMergingUsesOutsideLoop
lsr_narrow_by_merging_uses_outside_loop :: () {
    if lsr_estimate_search_space_complexity() < lsr_cl.complexity_limit return;
    lu_idx := 0;
    num_uses := lsr.uses.count;
    while lu_idx != num_uses {
        lu := *lsr.uses[lu_idx];
        if !lu.all_fixups_outside_loop || lu.formulae.count == 0 || lu.kind == .ICMP_ZERO { lu_idx += 1; continue; }
        merge_with := -1;
        this_f := *lu.formulae[0];
        for * other: lsr.uses {
            if other.all_fixups_outside_loop continue;
            if other.kind == .ICMP_ZERO continue;
            if other.formulae.count == 0 continue;
            bad := false;
            for * of: other.formulae if !lsr_is_legal_use_f(lu.min_offset, lu.max_offset, other.kind, other.access_ty, of) { bad = true; break; }
            if bad continue;
            other_f := *other.formulae[0];
            if lsr_key_eq(this_f.base_regs, other_f.base_regs) && this_f.scaled_reg == other_f.scaled_reg && this_f.base_gv == other_f.base_gv &&
               this_f.scale == other_f.scale && imm_eq(this_f.unfolded_offset, other_f.unfolded_offset) && imm_eq(this_f.base_offset, other_f.base_offset) {
                merge_with = it_index;
                break;
            }
        }
        if merge_with < 0 { lu_idx += 1; continue; }
        for * fx: lu.fixups lu_push_fixup(*lsr.uses[merge_with], fx.*);
        lsr_delete_use(lu_idx);
        num_uses -= 1;
    }
}

// NarrowSearchSpaceByDeletingCostlyFormulas (-lsr-exp-narrow)
lsr_narrow_by_deleting_costly_formulas :: () {
    if lsr_estimate_search_space_complexity() < lsr_cl.complexity_limit return;
    uniq_regs: [..] Scev_Id; uniq_regs.allocator = temp;
    reg_num_map: Table(Scev_Id, float32); reg_num_map.allocator = temp;
    for reg: lsr.reg_uses.sequence {
        if lsr_set_contains(uniq_regs, reg) continue;
        p_not_sel: float32 = 1;
        for * lu: lsr.uses {
            if !lsr_set_contains(lu.regs, reg) continue;
            p := lu_not_selected_probability(lu, reg);
            if p != 0.0 p_not_sel *= p;
            else lsr_set_insert(*uniq_regs, reg);
        }
        if !table_contains(*reg_num_map, reg) table_set(*reg_num_map, reg, p_not_sel);
    }
    rn :: (m: *Table(Scev_Id, float32), r: Scev_Id) -> float32 { found, v := table_find(m, r); if !found { table_set(m, r, 0); return 0; } return v; }
    for lu_idx: 0..lsr.uses.count-1 {
        lu := *lsr.uses[lu_idx];
        if lu.formulae.count < 2 continue;
        fmin_reg_num := cast(float32) lf_num_regs(*lu.formulae[0]);
        fmin_areg_num := cast(float32) lf_num_regs(*lu.formulae[0]);
        min_idx := 0;
        for * f, i: lu.formulae {
            freg_num: float32 = 0;
            fareg_num: float32 = 0;
            for br: f.base_regs {
                if lsr_set_contains(uniq_regs, br) continue;
                v := rn(*reg_num_map, br) / lu_not_selected_probability(lu, br);
                freg_num += v;
                if sc_kind(br) == .ADDREC fareg_num += v;
            }
            if f.scaled_reg != SCEV_NULL && !lsr_set_contains(uniq_regs, f.scaled_reg) {
                v := rn(*reg_num_map, f.scaled_reg) / lu_not_selected_probability(lu, f.scaled_reg);
                freg_num += v;
                if sc_kind(f.scaled_reg) == .ADDREC fareg_num += v;
            }
            if fmin_reg_num > freg_num || (fmin_reg_num == freg_num && fmin_areg_num > fareg_num) {
                fmin_reg_num = freg_num; fmin_areg_num = fareg_num; min_idx = i;
            }
        }
        if min_idx != 0 { t := lu.formulae[min_idx]; lu.formulae[min_idx] = lu.formulae[0]; lu.formulae[0] = t; }
        lu.formulae.count = 1;
        lu_recompute_regs(lu, lu_idx, *lsr.reg_uses);
        f := *lu.formulae[0];
        for f.base_regs lsr_set_insert(*uniq_regs, it);
        if f.scaled_reg != SCEV_NULL lsr_set_insert(*uniq_regs, f.scaled_reg);
    }
}

// IsSimplerBaseSCEVForTarget
lsr_is_simpler_base_scev_for_target :: (best: Scev_Id, reg: Scev_Id, at: Lsr_Mem_Ty) -> bool {
    if sc_type(best) != sc_type(reg) || (sc_kind(best) == .ADDREC && sc_kind(reg) == .ADDREC && sc_loop(best) != sc_loop(reg)) return false;
    ok, diff := sc_compute_constant_difference(best, reg);
    if !ok return false;
    d := ap_sext_value(diff);
    return lsr_is_legal_addressing_mode(at.mem_ty, NONE, d, true, 0, at.as, 0) &&
           !lsr_is_legal_addressing_mode(at.mem_ty, NONE, cast,no_check(s64) (0 - cast,no_check(u64) d), true, 0, at.as, 0);
}

// NarrowSearchSpaceByPickingWinnerRegs
lsr_narrow_by_picking_winner_regs :: () {
    taken: [..] Scev_Id; taken.allocator = temp;
    while lsr_estimate_search_space_complexity() >= lsr_cl.complexity_limit {
        best: Scev_Id = SCEV_NULL;
        best_num := 0;
        count_bits :: (b: [] bool) -> s64 { n := 0; for b if it n += 1; return n; }
        for reg: lsr.reg_uses.sequence {
            if lsr_set_contains(taken, reg) continue;
            ub := ru_used_by(*lsr.reg_uses, reg);
            if best == SCEV_NULL { best = reg; best_num = count_bits(ub); }
            else {
                count := count_bits(ub);
                if count > best_num { best = reg; best_num = count; }
                if count == best_num {
                    lu_idx := -1;
                    for ub if it { lu_idx = it_index; break; }
                    if lu_idx >= 0 && lsr.uses[lu_idx].kind == .ADDRESS && lsr_is_simpler_base_scev_for_target(best, reg, lsr.uses[lu_idx].access_ty) {
                        best = reg; best_num = count;
                    }
                }
            }
        }
        if best == SCEV_NULL fatal("loop-reduce: Failed to find best LSRUse candidate");
        array_add(*taken, best);
        for lu_idx: 0..lsr.uses.count-1 {
            lu := *lsr.uses[lu_idx];
            if !lsr_set_contains(lu.regs, best) continue;
            any := false;
            i := 0; e := lu.formulae.count;
            while i != e {
                if !lf_references_reg(*lu.formulae[i], best) {
                    lu_delete_formula(lu, i);
                    e -= 1; any = true;
                    continue;
                }
                i += 1;
            }
            if any lu_recompute_regs(lu, lu_idx, *lsr.reg_uses);
        }
    }
}

// NarrowSearchSpaceUsingHeuristics
lsr_narrow_search_space_using_heuristics :: () {
    lsr_narrow_by_detecting_supersets();
    lsr_narrow_by_collapsing_unrolled_code();
    if lsr_estimate_search_space_complexity() >= lsr_cl.complexity_limit lsr_filter_out_undesirable_dedicated_registers();
    if lsr_cl.filter_same_scaled_reg lsr_narrow_by_filter_formula_with_same_scaled_reg();
    // NarrowSearchSpaceByFilterPostInc: AMK_PostIndexed only
    lsr_narrow_by_merging_uses_outside_loop();
    if lsr_cl.exp_narrow lsr_narrow_by_deleting_costly_formulas();
    else lsr_narrow_by_picking_winner_regs();
}

// SolveRecurse
Lsr_Solver :: struct {
    solution: [..] s64;          // formula index per use
    solution_cost: Lsr_Cost;
    workspace: [..] s64;
    visited_regs: Table(Scev_Id, bool);
}
lsr_solve_recurse :: (sv: *Lsr_Solver, cur_cost: Lsr_Cost, cur_regs: [] Scev_Id) {
    lu := *lsr.uses[sv.workspace.count];
    req_regs: [..] Scev_Id; req_regs.allocator = temp;
    for cur_regs if lsr_set_contains(lu.regs, it) lsr_set_insert(*req_regs, it);
    new_regs: [..] Scev_Id; new_regs.allocator = temp;
    for * f, fi: lu.formulae {
        num_req := min(lf_num_regs(f), req_regs.count);
        for reg: req_regs {
            if (f.scaled_reg != SCEV_NULL && f.scaled_reg == reg) || lsr_set_contains(f.base_regs, reg) {
                num_req -= 1;
                if num_req == 0 break;
            }
        }
        if num_req != 0 continue;
        new_cost := cur_cost;
        new_regs.count = 0;
        for cur_regs array_add(*new_regs, it);
        cost_rate_formula(*new_cost, f, *new_regs, *sv.visited_regs, lu);
        if cost_is_less(*new_cost, *sv.solution_cost) {
            array_add(*sv.workspace, fi);
            if sv.workspace.count != lsr.uses.count {
                lsr_solve_recurse(sv, new_cost, new_regs);
                if lf_num_regs(f) == 1 && sv.workspace.count == 1
                    table_set(*sv.visited_regs, ifx f.scaled_reg != SCEV_NULL then f.scaled_reg else f.base_regs[0], true);
            } else {
                sv.solution_cost = new_cost;
                sv.solution.count = 0;
                for sv.workspace array_add(*sv.solution, it);
            }
            sv.workspace.count -= 1;
        }
    }
}

// Solve: the chosen formula index for each use (empty: no solution)
lsr_solve :: () -> [..] s64 {
    sv: Lsr_Solver;
    sv.solution.allocator = temp; sv.workspace.allocator = temp; sv.visited_regs.allocator = temp;
    cost_lose(*sv.solution_cost);
    cur_cost: Lsr_Cost;
    cur_regs: [..] Scev_Id; cur_regs.allocator = temp;
    lsr_solve_recurse(*sv, cur_cost, cur_regs);
    if sv.solution.count == 0 return sv.solution;
    // AllowDropSolutionIfLessProfitable: unset -> TTI.shouldDropLSRSolutionIfLessProfitable() (false on X86)
    enable_drop := lsr_cl.drop_solution == 1;
    if cost_is_less(*lsr.baseline_cost, *sv.solution_cost) && enable_drop sv.solution.count = 0;
    return sv.solution;
}
