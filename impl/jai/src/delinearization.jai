// Delinearization and SCEV division.
// Ports llvm/lib/Analysis/ScalarEvolutionDivision.cpp (SCEVDivision::divide and its visitor, print<scev-division>)
// and llvm/lib/Analysis/Delinearization.cpp (collectParametricTerms, findArrayDimensions, computeAccessFunctions,
// delinearize, findFixedSizeArrayDimensions, delinearizeFixedSizeArray, validateDelinearizationResult,
// print<delinearization>), plus ScalarEvolution::getElementSize. Used by DependenceAnalysis
// (dependence_analysis.jai).
//
// One LLVM behaviour can't be reproduced exactly: findArrayDimensions sorts the collected terms by SCEV *pointer*
// (array_pod_sort) before its stable-in-practice sort by number of factors. We order by Scev_Id, i.e. creation
// order, which is what BumpPtrAllocator addresses give within one slab (knowledge/llvm/dependence-analysis.md).

// SCEVTraversal::visitAll with a `follow` callback (isDone is always false for the visitors here)
da_visit_all :: (root: Scev_Id, follow: (s: Scev_Id, ctx: *void) -> bool, ctx: *void) {
    visited: Table(Scev_Id, bool); visited.allocator = temp;
    work: [..] Scev_Id; work.allocator = temp;
    push :: (s: Scev_Id, visited: *Table(Scev_Id, bool), work: *[..] Scev_Id, follow: (s: Scev_Id, ctx: *void) -> bool, ctx: *void) {
        if table_contains(visited, s) return;
        table_set(visited, s, true);
        if follow(s, ctx) array_add(work, s);
    }
    push(root, *visited, *work, follow, ctx);
    while work.count > 0 {
        s := pop(*work);
        k := sc_kind(s);
        if k == .CONSTANT || k == .VSCALE || k == .UNKNOWN || k == .CNC continue;
        for i: 0..cast(s64) sc_nops(s) - 1 push(sc_op(s, cast(u32) i), *visited, *work, follow, ctx);
    }
}

// sizeOfSCEV: the number of distinct nodes
sc_size_of_scev :: (s: Scev_Id) -> s64 {
    n: s64;
    da_visit_all(s, (x: Scev_Id, ctx: *void) -> bool { (cast(*s64) ctx).* += 1; return true; }, *n);
    return n;
}

// ---------------------------------------------------------------- SCEVDivision

Sc_Division :: struct {
    denominator: Scev_Id;
    quotient: Scev_Id;
    remainder: Scev_Id;
    zero: Scev_Id;
    one: Scev_Id;
}

// SCEVDivision::divide(SE, Numerator, Denominator, &Quotient, &Remainder)
sc_divide :: (numerator: Scev_Id, denominator: Scev_Id) -> (quotient: Scev_Id, remainder: Scev_Id) {
    assert(sc_type(numerator) == sc_type(denominator), "SCEVDivision: numerator and denominator types differ");
    // the SCEVDivision constructor: Zero, One, cannotDivide(Numerator)
    d: Sc_Division;
    d.denominator = denominator;
    d.zero = sc_get_zero(sc_type(denominator));
    d.one = sc_get_one(sc_type(denominator));
    d.quotient = d.zero; d.remainder = numerator;
    if numerator == denominator return d.one, d.zero;
    if sc_is_zero(numerator) return d.zero, d.zero;
    if sc_is_one(denominator) return numerator, d.zero;
    if sc_is_mul(denominator) {
        quotient := numerator;
        for k: 0..cast(s64) sc_nops(denominator) - 1 {
            q, r := sc_divide(quotient, sc_op(denominator, cast(u32) k));
            quotient = q;
            if !sc_is_zero(r) return d.zero, numerator;
        }
        return quotient, d.zero;
    }
    sc_division_visit(*d, numerator);
    return d.quotient, d.remainder;
}

sc_division_cannot_divide :: (d: *Sc_Division, numerator: Scev_Id) { d.quotient = d.zero; d.remainder = numerator; }

sc_division_visit :: (d: *Sc_Division, numerator: Scev_Id) {
    k := sc_kind(numerator);
    if k == {
        case .CONSTANT;
            if !sc_is_const(d.denominator) return;
            nv := sc_ap(numerator); dv := sc_ap(d.denominator);
            if ap_is_zero(dv) fatal("SCEVDivision: division of a constant by zero");
            d.quotient = sc_get_constant(ap_sdiv(nv, dv));
            d.remainder = sc_get_constant(ap_srem(nv, dv));
        case .VSCALE; sc_division_cannot_divide(d, numerator);
        case .ADDREC;
            if !sc_is_affine(numerator) { sc_division_cannot_divide(d, numerator); return; }
            start_q, start_r := sc_divide(sc_start(numerator), d.denominator);
            step_q, step_r := sc_divide(sc_step_recurrence(numerator), d.denominator);
            ty := sc_type(d.denominator);
            if ty != sc_type(start_q) || ty != sc_type(start_r) || ty != sc_type(step_q) || ty != sc_type(step_r) {
                sc_division_cannot_divide(d, numerator);
                return;
            }
            d.quotient = sc_get_add_rec(start_q, step_q, sc_loop(numerator), SF_ANY);
            d.remainder = sc_get_add_rec(start_r, step_r, sc_loop(numerator), SF_ANY);
        case .ADD;
            qs: [..] Scev_Id; qs.allocator = temp;
            rs: [..] Scev_Id; rs.allocator = temp;
            ty := sc_type(d.denominator);
            for i: 0..cast(s64) sc_nops(numerator) - 1 {
                q, r := sc_divide(sc_op(numerator, cast(u32) i), d.denominator);
                if ty != sc_type(q) || ty != sc_type(r) { sc_division_cannot_divide(d, numerator); return; }
                array_add(*qs, q); array_add(*rs, r);
            }
            if qs.count == 1 { d.quotient = qs[0]; d.remainder = rs[0]; return; }
            d.quotient = sc_get_add(*qs);
            d.remainder = sc_get_add(*rs);
        case .MUL;
            qs: [..] Scev_Id; qs.allocator = temp;
            ty := sc_type(d.denominator);
            found := false;
            for i: 0..cast(s64) sc_nops(numerator) - 1 {
                o := sc_op(numerator, cast(u32) i);
                if ty != sc_type(o) { sc_division_cannot_divide(d, numerator); return; }
                if found { array_add(*qs, o); continue; }
                q, r := sc_divide(o, d.denominator);
                if !sc_is_zero(r) { array_add(*qs, o); continue; }
                if ty != sc_type(q) { sc_division_cannot_divide(d, numerator); return; }
                found = true;
                array_add(*qs, q);
            }
            if found {
                d.remainder = d.zero;
                if qs.count == 1 d.quotient = qs[0];
                else d.quotient = sc_get_mul(*qs);
                return;
            }
            if !sc_is_unknown(d.denominator) { sc_division_cannot_divide(d, numerator); return; }
            // SCEVParameterRewriter with Denominator -> 0, then -> 1
            d.remainder = sc_rewrite_parameter(numerator, sc_value(d.denominator), d.zero);
            if sc_is_zero(d.remainder) {
                d.quotient = sc_rewrite_parameter(numerator, sc_value(d.denominator), d.one);
                return;
            }
            diff := sc_get_minus(numerator, d.remainder);
            if sc_size_of_scev(diff) > sc_size_of_scev(numerator) { sc_division_cannot_divide(d, numerator); return; }
            q, r := sc_divide(diff, d.denominator);
            if r != d.zero { sc_division_cannot_divide(d, numerator); return; }
            d.quotient = q;
        // everything else (casts, udiv, min/max, unknown, CouldNotCompute) keeps cannotDivide's result
    }
}

// SCEVParameterRewriter::rewrite with a one-entry map {value -> to} (the PARAMETER rewriter, scev_create.jai)
sc_rewrite_parameter :: (s: Scev_Id, value: Value_Id, to: Scev_Id) -> Scev_Id {
    map: Table(Value_Id, Scev_Id); map.allocator = temp;
    table_set(*map, value, to);
    rw: Sc_Rewriter;
    sc_rewriter_init(*rw, .PARAMETER);
    rw.param_map = *map;
    return sc_rewrite(*rw, s);
}

// SCEVDivisionPrinterPass::run (print<scev-division>)
scev_division_printer_run :: (f: Value_Id) -> Preserved {
    se = get_scev(f);
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis 'Scalar Evolution Division' for function '%':\n", vname(f));
    for b: fn_blocks(f) for i: block_insts(b) {
        if inst_op(i) != .SDIV || is_vector_type(vtype(i)) continue;
        num := sc_get_scev(op(i, 0));
        den := sc_get_scev(op(i, 1));
        q, r := sc_divide(num, den);
        append(*sb, "Instruction: "); append(*sb, inst_to_string(i)); append(*sb, "\n");
        append(*sb, "  Numerator: "); sc_print(*sb, num); append(*sb, "\n");
        append(*sb, "  Denominator: "); sc_print(*sb, den); append(*sb, "\n");
        append(*sb, "  Quotient: "); sc_print(*sb, q); append(*sb, "\n");
        append(*sb, "  Remainder: "); sc_print(*sb, r); append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- Delinearization

delin_opts: struct {
    use_fixed_size_array_heuristic := true;   // -delinearize-use-fixed-size-array-heuristic
};

// ScalarEvolution::getElementSize(Inst)
sc_get_element_size :: (i: Value_Id) -> Scev_Id {
    ty: Type_Id;
    if inst_op(i) == .STORE ty = vtype(op(i, 0));
    else if inst_op(i) == .LOAD ty = vtype(i);
    else return SCEV_NULL;
    ety := sc_effective_type(ir.t_ptr);
    return sc_get_size_of(ety, ty);
}

delin_contains_undefs :: (s: Scev_Id) -> bool {
    found := false;
    da_visit_all(s, (x: Scev_Id, ctx: *void) -> bool {
        f := cast(*bool) ctx;
        if f.* return false;
        if sc_is_unknown(x) { k := vkind(sc_value(x)); if k == .C_UNDEF || k == .C_POISON { f.* = true; return false; } }
        return true;
    }, *found);
    return found;
}

// collectParametricTerms(SE, Expr, Terms)
delin_collect_parametric_terms :: (expr: Scev_Id, terms: *[..] Scev_Id) {
    strides: [..] Scev_Id; strides.allocator = temp;
    // SCEVCollectStrides
    da_visit_all(expr, (s: Scev_Id, ctx: *void) -> bool {
        if !sc_is_addrec(s) || !sc_is_affine(s) return false;
        array_add(cast(*[..] Scev_Id) ctx, sc_step_recurrence(s));
        return true;
    }, *strides);
    // SCEVCollectTerms on every stride
    for s: strides {
        da_visit_all(s, (x: Scev_Id, ctx: *void) -> bool {
            k := sc_kind(x);
            if k == .UNKNOWN || k == .MUL || k == .SEXT
                if !delin_contains_undefs(x) array_add(cast(*[..] Scev_Id) ctx, x);
            return k == .ADD || k == .ADDREC;
        }, terms);
    }
    // SCEVCollectAddRecMultiplies
    da_visit_all(expr, (s: Scev_Id, ctx: *void) -> bool {
        k := sc_kind(s);
        if k == .MUL {
            has_add_rec := false;
            ops: [..] Scev_Id; ops.allocator = temp;
            for i: 0..cast(s64) sc_nops(s) - 1 {
                o := sc_op(s, cast(u32) i);
                if sc_is_unknown(o) {
                    v := sc_value(o);
                    if is_inst(v) && inst_op(v) == .CALL has_add_rec = true;
                    else array_add(*ops, o);
                } else {
                    has_add_rec |= sc_expr_contains(o, .CONTAINS_ADDREC);
                }
            }
            if ops.count == 0 return true;
            if !has_add_rec return false;
            array_add(cast(*[..] Scev_Id) ctx, sc_get_mul(*ops));
        }
        return k == .ADD || k == .ADDREC;
    }, terms);
}

delin_number_of_terms :: (s: Scev_Id) -> s64 { if sc_is_mul(s) return cast(s64) sc_nops(s); return 1; }

// findArrayDimensionsRec
delin_find_array_dimensions_rec :: (terms: *[..] Scev_Id, sizes: *[..] Scev_Id) -> bool {
    last := terms.count - 1;
    step := terms.*[last];
    if last == 0 {
        if sc_is_mul(step) {
            qs: [..] Scev_Id; qs.allocator = temp;
            for i: 0..cast(s64) sc_nops(step) - 1 { o := sc_op(step, cast(u32) i); if !sc_is_const(o) array_add(*qs, o); }
            step = sc_get_mul(*qs);
        }
        array_add(sizes, step);
        return true;
    }
    for * t: terms.* {
        q, r := sc_divide(t.*, step);
        if !sc_is_zero(r) return false;
        t.* = q;
    }
    // erase_if(isa<SCEVConstant>)
    k := 0;
    for terms.* if !sc_is_const(it) { terms.*[k] = it; k += 1; }
    terms.count = k;
    if terms.count > 0
        if !delin_find_array_dimensions_rec(terms, sizes) return false;
    array_add(sizes, step);
    return true;
}

// findArrayDimensions(SE, Terms, Sizes, ElementSize)
delin_find_array_dimensions :: (terms: *[..] Scev_Id, sizes: *[..] Scev_Id, element_size: Scev_Id) {
    if terms.count < 1 || element_size == SCEV_NULL return;
    // containsParameters
    has_params := false;
    for terms.* if sc_expr_contains_unknown(it) { has_params = true; break; }
    if !has_params return;
    // array_pod_sort by SCEV address (approximated by creation order), then unique
    quick_sort(terms.*, (a: Scev_Id, b: Scev_Id) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
    k := 0;
    for terms.* { if k > 0 && terms.*[k - 1] == it continue; terms.*[k] = it; k += 1; }
    terms.count = k;
    // llvm::sort by number of factors, decreasing (std::sort is an insertion sort, so stable, up to 16 elements)
    for i: 1..terms.count - 1 {
        x := terms.*[i];
        j := i;
        while j > 0 && delin_number_of_terms(x) > delin_number_of_terms(terms.*[j - 1]) { terms.*[j] = terms.*[j - 1]; j -= 1; }
        terms.*[j] = x;
    }
    if terms.count > 16 fatal("delinearization: sorting more than 16 parametric terms (std::sort's unstable introsort) is not supported yet");
    // divide by the element size
    for * t: terms.* {
        q, r := sc_divide(t.*, element_size);
        if !sc_is_zero(q) t.* = q;
    }
    new_terms: [..] Scev_Id; new_terms.allocator = temp;
    for t: terms.* {
        // removeConstantFactors
        if sc_is_const(t) continue;
        if sc_is_unknown(t) { array_add(*new_terms, t); continue; }
        if sc_is_mul(t) {
            factors: [..] Scev_Id; factors.allocator = temp;
            for i: 0..cast(s64) sc_nops(t) - 1 { o := sc_op(t, cast(u32) i); if !sc_is_const(o) array_add(*factors, o); }
            array_add(*new_terms, sc_get_mul(*factors));
            continue;
        }
        array_add(*new_terms, t);
    }
    if new_terms.count == 0 || !delin_find_array_dimensions_rec(*new_terms, sizes) {
        sizes.count = 0;
        return;
    }
    array_add(sizes, element_size);
}

sc_expr_contains_unknown :: (s: Scev_Id) -> bool {
    found := false;
    da_visit_all(s, (x: Scev_Id, ctx: *void) -> bool {
        f := cast(*bool) ctx;
        if f.* return false;
        if sc_is_unknown(x) { f.* = true; return false; }
        return true;
    }, *found);
    return found;
}

// computeAccessFunctions(SE, Expr, Subscripts, Sizes)
delin_compute_access_functions :: (expr: Scev_Id, subscripts: *[..] Scev_Id, sizes: *[..] Scev_Id) {
    if sizes.count == 0 return;
    if sc_is_addrec(expr) && !sc_is_affine(expr) return;
    subscripts.count = 0;
    res := expr;
    last := sizes.count - 1;
    i := last;
    while i >= 0 {
        q, r := sc_divide(res, sizes.*[i]);
        res = q;
        if i == last {
            if !sc_is_zero(r) { subscripts.count = 0; sizes.count = 0; return; }
            i -= 1;
            continue;
        }
        array_add(subscripts, r);
        i -= 1;
    }
    array_add(subscripts, res);
    // std::reverse
    n := subscripts.count;
    for j: 0..n / 2 - 1 { t := subscripts.*[j]; subscripts.*[j] = subscripts.*[n - 1 - j]; subscripts.*[n - 1 - j] = t; }
}

// delinearize(SE, Expr, Subscripts, Sizes, ElementSize)
delin_delinearize :: (expr: Scev_Id, subscripts: *[..] Scev_Id, sizes: *[..] Scev_Id, element_size: Scev_Id) {
    subscripts.count = 0; sizes.count = 0;
    terms: [..] Scev_Id; terms.allocator = temp;
    delin_collect_parametric_terms(expr, *terms);
    if terms.count == 0 return;
    delin_find_array_dimensions(*terms, sizes, element_size);
    if sizes.count == 0 return;
    delin_compute_access_functions(expr, subscripts, sizes);
}

// collectConstantAbsSteps
delin_collect_constant_abs_steps :: (expr: Scev_Id, steps: *[..] u64, element_size: u64) -> bool {
    if sc_is_const(expr) return ap_urem_u64(sc_ap(expr), element_size) == 0;
    if !sc_is_addrec(expr) || !sc_is_affine(expr) return false;
    step := sc_step_recurrence(expr);
    if !sc_is_const(step) return false;
    a := ap_abs(sc_ap(step));
    if ap_urem_u64(a, element_size) != 0 return false;
    q := ap_udiv(a, ap_from_u64(a.bits, element_size));
    if !ap_fits_u64(q) return false;
    array_add(steps, ap_zext_value(q));
    return delin_collect_constant_abs_steps(sc_start(expr), steps, element_size);
}

// findFixedSizeArrayDimensions(SE, Expr, Sizes, ElementSize)
delin_find_fixed_size_array_dimensions :: (expr: Scev_Id, sizes: *[..] u64, element_size: Scev_Id) -> bool {
    if element_size == SCEV_NULL || !sc_is_const(element_size) return false;
    es := sc_ap(element_size);
    if ap_is_zero(es) return false;
    if !ap_fits_u64(es) return false;
    esc := ap_zext_value(es);
    if !delin_collect_constant_abs_steps(expr, sizes, esc) || sizes.count == 0 { sizes.count = 0; return false; }
    // llvm::sort(Sizes.rbegin(), Sizes.rend()): decreasing, then unique
    quick_sort(sizes.*, (a: u64, b: u64) -> s64 { return ifx a > b then -1 else ifx a < b then 1 else 0; });
    k := 0;
    for sizes.* { if k > 0 && sizes.*[k - 1] == it continue; sizes.*[k] = it; k += 1; }
    sizes.count = k;
    sizes.*[sizes.count - 1] = 1;
    for i: 0..sizes.count - 2 {
        prev := sizes.*[i + 1];
        if sizes.*[i] % prev != 0 { sizes.count = 0; return false; }
        sizes.*[i] /= prev;
    }
    sizes.*[sizes.count - 1] = esc;
    return true;
}

// delinearizeFixedSizeArray(SE, Expr, Subscripts, Sizes, ElementSize)
delin_delinearize_fixed_size_array :: (expr: Scev_Id, subscripts: *[..] Scev_Id, sizes: *[..] Scev_Id, element_size: Scev_Id) -> bool {
    subscripts.count = 0; sizes.count = 0;
    const_sizes: [..] u64; const_sizes.allocator = temp;
    if !delin_find_fixed_size_array_dimensions(expr, *const_sizes, element_size) { sizes.count = 0; return false; }
    for const_sizes array_add(sizes, sc_get_constant_t(sc_type(expr), it));
    delin_compute_access_functions(expr, subscripts, sizes);
    return subscripts.count > 0;
}

// validateDelinearizationResult(SE, Sizes, Subscripts)
delin_validate :: (sizes: [] Scev_Id, subscripts: [] Scev_Id) -> bool {
    add_overflow :: (a: Scev_Id, b: Scev_Id) -> Scev_Id {
        if !sc_will_not_overflow(.ADD, true, a, b) return SCEV_NULL;
        return sc_get_add2(a, b);
    }
    mul_overflow :: (a: Scev_Id, b: Scev_Id) -> Scev_Id {
        if !sc_will_not_overflow(.MUL, true, a, b) return SCEV_NULL;
        return sc_get_mul2(a, b);
    }
    for i: 1..sizes.count - 1 {
        size := sizes[i - 1];
        subscript := subscripts[i];
        if !sc_is_known_non_negative(subscript) return false;
        wider := sc_get_wider_type(sc_type(subscript), sc_type(size));
        subscript = sc_get_noop_or_sign_extend(subscript, wider);
        size = sc_get_noop_or_sign_extend(size, wider);
        if !sc_is_known_predicate(ICMP_SLT, subscript, size) return false;
    }
    prod := sc_get_one(sc_type(sizes[0]));
    for size: sizes {
        prod = mul_overflow(prod, size);
        if prod == SCEV_NULL return false;
    }
    mn := mul_overflow(prod, subscripts[0]);
    if mn == SCEV_NULL return false;
    max_plus_one := add_overflow(mn, prod);
    if max_plus_one == SCEV_NULL return false;
    if !sc_will_not_overflow(.SUB, true, max_plus_one, sc_get_one(sc_type(max_plus_one))) return false;
    return true;
}

// DelinearizationPrinterPass::run (print<delinearization>)
delinearization_printer_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    se = get_scev(f);
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis 'Delinearization' for function '%':", vname(f));
    done := false;
    for b: fn_blocks(f) {
        if done break;
        for i: block_insts(b) {
            o := inst_op(i);
            if o != .STORE && o != .LOAD continue;
            l := li_loop_for(li, b);
            if l == NONE continue;
            access_fn := sc_get_scev_at_scope(sc_get_scev(load_store_pointer_operand(i)), l);
            base := sc_get_pointer_base(access_fn);
            if !sc_is_unknown(base) { done = true; break; }
            access_fn = sc_get_minus(access_fn, base);
            append(*sb, "\n");
            append(*sb, "Inst:"); append(*sb, inst_to_string(i)); append(*sb, "\n");
            append(*sb, "AccessFunction: "); sc_print(*sb, access_fn); append(*sb, "\n");
            subscripts: [..] Scev_Id; subscripts.allocator = temp;
            sizes: [..] Scev_Id; sizes.allocator = temp;
            failed :: (subscripts: [] Scev_Id, sizes: [] Scev_Id) -> bool {
                return subscripts.count == 0 || sizes.count == 0 || subscripts.count != sizes.count;
            }
            delin_delinearize(access_fn, *subscripts, *sizes, sc_get_element_size(i));
            if delin_opts.use_fixed_size_array_heuristic && failed(subscripts, sizes) {
                subscripts.count = 0; sizes.count = 0;
                delin_delinearize_fixed_size_array(access_fn, *subscripts, *sizes, sc_get_element_size(i));
            }
            if failed(subscripts, sizes) { append(*sb, "failed to delinearize\n"); continue; }
            append(*sb, "Base offset: "); sc_print(*sb, base); append(*sb, "\n");
            append(*sb, "ArrayDecl[UnknownSize]");
            n := subscripts.count;
            for k: 0..n - 2 { append(*sb, "["); sc_print(*sb, sizes[k]); append(*sb, "]"); }
            append(*sb, " with elements of "); sc_print(*sb, sizes[n - 1]); append(*sb, " bytes.\n");
            append(*sb, "ArrayRef");
            for k: 0..n - 1 { append(*sb, "["); sc_print(*sb, subscripts[k]); append(*sb, "]"); }
            append(*sb, "\n");
            valid := delin_validate(sizes, subscripts);
            print_to_builder(*sb, "Delinearization validation: %\n", ifx valid then "Succeeded" else "Failed");
        }
    }
    // (no newline after the last instruction, as in LLVM)
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
