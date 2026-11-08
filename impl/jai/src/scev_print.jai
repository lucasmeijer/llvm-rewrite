// ScalarEvolution, part 8: the analysis result, the printer pass and the cl::opts.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): ScalarEvolutionAnalysis::run / invalidate,
// ScalarEvolution::print with PrintLoopInfo / PrintSCEVWithTypeHint, ScalarEvolutionPrinterPass,
// ScalarEvolutionVerifierPass (see NOTES.md: the verifier's recomputation is not ported, it fails loudly).

// AM.getResult<ScalarEvolutionAnalysis>(F): TLI, AssumptionCache, DominatorTree, LoopInfo, in that order
get_scev :: (f: Value_Id) -> *Scev_State {
    e := fam_entry(f);
    if !e.se {
        ac := get_assumption_cache(f);
        dt := get_domtree(f);
        li := get_loop_info(f);
        e = fam_entry(f);
        e.se = scev_new(f, dt, li, ac);
    }
    se = e.se;
    return e.se;
}
cached_scev :: (f: Value_Id) -> *Scev_State { e := table_find_pointer(*fam, f); if e return e.se; return null; }

// PrintSCEVWithTypeHint
print_scev_with_type_hint :: (sb: *String_Builder, s: Scev_Id) {
    if sc_is_const(s) { append(sb, type_to_string(sc_type(s))); append(sb, " "); }
    sc_print(sb, s);
}

// PrintLoopInfo
print_scev_loop_info :: (sb: *String_Builder, l: Loop_Id) {
    for sub: li_subloops(se.li, l) print_scev_loop_info(sb, sub);
    header := value_as_operand(li_header(se.li, l));
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(se.li, l, *exiting);

    append(sb, "Loop "); append(sb, header); append(sb, ": ");
    if exiting.count != 1 append(sb, "<multiple exits> ");
    btc := sc_get_backedge_taken_count(l);
    if btc != SCEV_CNC { append(sb, "backedge-taken count is "); print_scev_with_type_hint(sb, btc); }
    else append(sb, "Unpredictable backedge-taken count.");
    append(sb, "\n");
    if exiting.count > 1 {
        for eb: exiting {
            append(sb, "  exit count for "); append(sb, vname(eb)); append(sb, ": ");
            ec := sc_get_exit_count(l, eb);
            print_scev_with_type_hint(sb, ec);
            if ec == SCEV_CNC {
                preds: [..] u32; preds.allocator = temp;
                ec = sc_get_predicated_exit_count(l, eb, *preds);
                if ec != SCEV_CNC {
                    append(sb, "\n  predicated exit count for "); append(sb, vname(eb)); append(sb, ": ");
                    print_scev_with_type_hint(sb, ec);
                    append(sb, "\n   Predicates:\n");
                    for preds sc_pred_print(sb, it, 4);
                }
            }
            append(sb, "\n");
        }
    }

    append(sb, "Loop "); append(sb, header); append(sb, ": ");
    constant_btc := sc_get_constant_max_backedge_taken_count(l);
    if constant_btc != SCEV_CNC {
        append(sb, "constant max backedge-taken count is ");
        print_scev_with_type_hint(sb, constant_btc);
        if sc_is_backedge_taken_count_max_or_zero(l) append(sb, ", actual taken count either this or zero.");
    } else append(sb, "Unpredictable constant max backedge-taken count. ");
    append(sb, "\nLoop "); append(sb, header); append(sb, ": ");
    symbolic_btc := sc_get_symbolic_max_backedge_taken_count(l);
    if symbolic_btc != SCEV_CNC {
        append(sb, "symbolic max backedge-taken count is ");
        print_scev_with_type_hint(sb, symbolic_btc);
        if sc_is_backedge_taken_count_max_or_zero(l) append(sb, ", actual taken count either this or zero.");
    } else append(sb, "Unpredictable symbolic max backedge-taken count. ");
    append(sb, "\n");
    if exiting.count > 1 {
        for eb: exiting {
            append(sb, "  symbolic max exit count for "); append(sb, vname(eb)); append(sb, ": ");
            ebtc := sc_get_exit_count(l, eb, .SYMBOLIC_MAX);
            print_scev_with_type_hint(sb, ebtc);
            if ebtc == SCEV_CNC {
                preds: [..] u32; preds.allocator = temp;
                ebtc = sc_get_predicated_exit_count(l, eb, *preds, .SYMBOLIC_MAX);
                if ebtc != SCEV_CNC {
                    append(sb, "\n  predicated symbolic max exit count for "); append(sb, vname(eb)); append(sb, ": ");
                    print_scev_with_type_hint(sb, ebtc);
                    append(sb, "\n   Predicates:\n");
                    for preds sc_pred_print(sb, it, 4);
                }
            }
            append(sb, "\n");
        }
    }

    {
        preds: [..] u32; preds.allocator = temp;
        pbt := sc_get_predicated_backedge_taken_count(l, *preds);
        if pbt != btc {
            append(sb, "Loop "); append(sb, header); append(sb, ": ");
            if pbt != SCEV_CNC { append(sb, "Predicated backedge-taken count is "); print_scev_with_type_hint(sb, pbt); }
            else append(sb, "Unpredictable predicated backedge-taken count.");
            append(sb, "\n Predicates:\n");
            for preds sc_pred_print(sb, it, 4);
        }
    }
    {
        preds: [..] u32; preds.allocator = temp;
        pcm := sc_get_predicated_constant_max_backedge_taken_count(l, *preds);
        if pcm != constant_btc {
            append(sb, "Loop "); append(sb, header); append(sb, ": ");
            if pcm != SCEV_CNC { append(sb, "Predicated constant max backedge-taken count is "); print_scev_with_type_hint(sb, pcm); }
            else append(sb, "Unpredictable predicated constant max backedge-taken count.");
            append(sb, "\n Predicates:\n");
            for preds sc_pred_print(sb, it, 4);
        }
    }
    {
        preds: [..] u32; preds.allocator = temp;
        psm := sc_get_predicated_symbolic_max_backedge_taken_count(l, *preds);
        if symbolic_btc != psm {
            append(sb, "Loop "); append(sb, header); append(sb, ": ");
            if psm != SCEV_CNC { append(sb, "Predicated symbolic max backedge-taken count is "); print_scev_with_type_hint(sb, psm); }
            else append(sb, "Unpredictable predicated symbolic max backedge-taken count.");
            append(sb, "\n Predicates:\n");
            for preds sc_pred_print(sb, it, 4);
        }
    }
    if sc_has_loop_invariant_backedge_taken_count(l) {
        append(sb, "Loop "); append(sb, header); append(sb, ": ");
        print_to_builder(sb, "Trip multiple is %\n", sc_get_small_constant_trip_multiple(l));
    }
}

loop_disposition_name :: (d: Loop_Disposition) -> string {
    if d == {
        case .VARIANT; return "Variant";
        case .INVARIANT; return "Invariant";
        case .UNIFORM; return "Uniform";
        case .COMPUTABLE; return "Computable";
    }
    return "";
}

// ScalarEvolution::print
scev_print_function :: (f: Value_Id, sb: *String_Builder) {
    if scev_opts.classify_expressions {
        printer_begin_function(f);
        append(sb, "Classifying expressions for: "); append(sb, value_as_operand(f)); append(sb, "\n");
        for i: fn_insts(f) {
            if !sc_is_scevable(vtype(i)) || inst_op(i) == .ICMP || inst_op(i) == .FCMP continue;
            append(sb, inst_to_string(i)); append(sb, "\n");
            append(sb, "  -->  ");
            sv := sc_get_scev(i);
            sc_print(sb, sv);
            if sv != SCEV_CNC {
                append(sb, " U: "); cr_print_to(sb, sc_unsigned_range(sv));
                append(sb, " S: "); cr_print_to(sb, sc_signed_range(sv));
            }
            l := li_loop_for(se.li, inst_block(i));
            at_use := sc_get_scev_at_scope(sv, l);
            if at_use != sv {
                append(sb, "  -->  ");
                sc_print(sb, at_use);
                if at_use != SCEV_CNC {
                    append(sb, " U: "); cr_print_to(sb, sc_unsigned_range(at_use));
                    append(sb, " S: "); cr_print_to(sb, sc_signed_range(at_use));
                }
            }
            if l != NONE {
                append(sb, "\t\tExits: ");
                exit_value := sc_get_scev_at_scope(sv, li_parent(se.li, l));
                if !sc_is_loop_invariant(exit_value, l) append(sb, "<<Unknown>>");
                else sc_print(sb, exit_value);
                first := true;
                sep :: (sb: *String_Builder, first: *bool) {
                    if first.* { append(sb, "\t\tLoopDispositions: { "); first.* = false; }
                    else append(sb, ", ");
                }
                it_l := l;
                while it_l != NONE {
                    sep(sb, *first);
                    append(sb, value_as_operand(li_header(se.li, it_l)));
                    append(sb, ": ");
                    append(sb, loop_disposition_name(sc_get_loop_disposition(sv, it_l)));
                    it_l = li_parent(se.li, it_l);
                }
                // depth_first(L), skipping L itself
                stack: [..] Loop_Id; stack.allocator = temp;
                order: [..] Loop_Id; order.allocator = temp;
                dfs :: (l: Loop_Id, order: *[..] Loop_Id) {
                    array_add(order, l);
                    for sub: li_subloops(se.li, l) dfs(sub, order);
                }
                dfs(l, *order);
                for inner: order {
                    if inner == l continue;
                    sep(sb, *first);
                    append(sb, value_as_operand(li_header(se.li, inner)));
                    append(sb, ": ");
                    append(sb, loop_disposition_name(sc_get_loop_disposition(sv, inner)));
                }
                append(sb, " }");
            }
            append(sb, "\n");
        }
    }
    printer_begin_function(f);
    append(sb, "Determining loop execution counts for: "); append(sb, value_as_operand(f)); append(sb, "\n");
    for l: se.li.top_level print_scev_loop_info(sb, l);
}

// ScalarEvolutionPrinterPass::run
scev_printer_run :: (f: Value_Id) {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis 'Scalar Evolution Analysis' for function '%':\n", vname(f));
    get_scev(f);
    scev_print_function(f, *sb);
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}

// ScalarEvolutionVerifierPass::run: getResult, then verify()
scev_verifier_run :: (f: Value_Id) {
    get_scev(f);
    scev_verify();
}
// ScalarEvolution::verify: recomputes every cached result in a fresh ScalarEvolution and reports differences.
// Not ported yet: running it would print nothing for a correct analysis, but we can't tell, so fail loudly when
// there is something to check.
scev_verify :: () {
    if se.btc.count == 0 && se.value_expr.count == 0 return;
    fatal("ScalarEvolution::verify (verify<scalar-evolution>, -verify-scev) is not implemented yet");
}

SCEV_CL_OPT_COUNT :: 17;
add_scev_cl_opts :: (list: [] Cl_Opt, start: s64) {
    o := *scev_opts;
    entries := Cl_Opt.[
        .{"scalar-evolution-max-iterations", .INT, null, null, null},
        .{"verify-scev", .BOOL, null, null, null},
        .{"scev-mulops-inline-threshold", .INT, null, null, null},
        .{"scev-addops-inline-threshold", .INT, null, null, null},
        .{"scalar-evolution-max-scev-compare-depth", .INT, null, null, null},
        .{"scalar-evolution-max-scev-operations-implication-depth", .INT, null, null, null},
        .{"scalar-evolution-max-value-compare-depth", .INT, null, null, null},
        .{"scalar-evolution-max-arith-depth", .INT, null, null, null},
        .{"scalar-evolution-max-constant-evolving-depth", .INT, null, null, null},
        .{"scalar-evolution-max-cast-depth", .INT, null, null, null},
        .{"scalar-evolution-max-add-rec-size", .INT, null, null, null},
        .{"scalar-evolution-huge-expr-threshold", .INT, null, null, null},
        .{"scev-range-iter-threshold", .INT, null, null, null},
        .{"scalar-evolution-max-loop-guard-collection-depth", .INT, null, null, null},
        .{"scalar-evolution-classify-expressions", .BOOL, null, null, null},
        .{"scalar-evolution-use-expensive-range-sharpening", .BOOL, null, null, null},
        .{"scalar-evolution-use-context-for-no-wrap-flag-inference", .BOOL, null, null, null},
    ];
    for entries list[start + it_index] = it;
    list[start + 0].i = cast(*s64) *o.max_brute_force_iterations;
    list[start + 1].b = *o.verify_scev;
    list[start + 2].i = cast(*s64) *o.mulops_inline_threshold;
    list[start + 3].i = cast(*s64) *o.addops_inline_threshold;
    list[start + 4].i = cast(*s64) *o.max_scev_compare_depth;
    list[start + 5].i = cast(*s64) *o.max_scev_operations_implication_depth;
    list[start + 6].i = cast(*s64) *o.max_value_compare_depth;
    list[start + 7].i = cast(*s64) *o.max_arith_depth;
    list[start + 8].i = cast(*s64) *o.max_constant_evolving_depth;
    list[start + 9].i = cast(*s64) *o.max_cast_depth;
    list[start + 10].i = cast(*s64) *o.max_add_rec_size;
    list[start + 11].i = cast(*s64) *o.huge_expr_threshold;
    list[start + 12].i = cast(*s64) *o.range_iter_threshold;
    list[start + 13].i = cast(*s64) *o.max_loop_guard_collection_depth;
    list[start + 14].b = *o.classify_expressions;
    list[start + 15].b = *o.use_expensive_range_sharpening;
    list[start + 16].b = *o.use_context_for_no_wrap_flag_inference;
}
