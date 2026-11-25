// prof-inject (ProfileInjectorPass) and prof-verify (ProfileVerifierPass).
// Ported from llvm/lib/Transforms/Utils/ProfileVerify.cpp.

prof_verify_cl: struct {
    default_function_entry_count: s64 = 1000;   // -profcheck-default-function-entry-count
    annotate_select := true;                    // -profcheck-annotate-select
    weights_for_test := false;                  // -profcheck-weights-for-test
    select_true_weight: u32 = 2;                // -profcheck-default-select-true-weight
    select_false_weight: u32 = 3;               // -profcheck-default-select-false-weight
}

prof_verify_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "profcheck-default-function-entry-count"; prof_verify_cl.default_function_entry_count = smisc_int(name, value, has_value);
        case "profcheck-annotate-select"; prof_verify_cl.annotate_select = smisc_bool(name, value, has_value);
        case "profcheck-weights-for-test"; prof_verify_cl.weights_for_test = smisc_bool(name, value, has_value);
        case "profcheck-default-select-true-weight"; prof_verify_cl.select_true_weight = cast(u32) smisc_int(name, value, has_value);
        case "profcheck-default-select-false-weight"; prof_verify_cl.select_false_weight = cast(u32) smisc_int(name, value, has_value);
        case; return false;
    }
    return true;
}
prof_verify_takes_value :: (n: string) -> bool {
    return n == "profcheck-default-function-entry-count" || n == "profcheck-default-select-true-weight" ||
           n == "profcheck-default-select-false-weight";
}

// ProfileInjector::getTerminatorBenefitingFromMDProf
pv_terminator_benefiting_from_md_prof :: (bb: Value_Id) -> Value_Id {
    t := block_terminator(bb);
    if t == NONE || num_successors(t) < 2 return NONE;
    o := inst_op(t);
    if o == .CONDBR || o == .SWITCH || o == .INDIRECTBR || o == .CALLBR return t;
    return NONE;
}

// isAsmOnly
pv_is_asm_only :: (f: Value_Id) -> bool {
    if !fn_has_fn_attr(f, .Naked) return false;
    for bb: fn_blocks(f) for i: block_insts(bb) {
        if i == block_terminator(bb) continue;   // drop_end(BB)
        if !is_call_base(i) || !call_is_inline_asm(i) return false;
    }
    return true;
}

// LLVMContext::emitError under opt's diagnostic handler: print, remember, and fail (no output) after the pipeline
ctx_has_errors := false;
ctx_emit_error :: (msg: string) {
    print_to_stderr("error: %\n", msg);
    ctx_has_errors = true;
}

pv_emit_profile_error :: (msg: string, f: Value_Id) {
    ctx_emit_error(tprint("Profile verification failed for function '%': %", vname(f), msg));
}

// ProfileInjector::inject
prof_inject_run :: (f: Value_Id) -> Preserved {
    if pv_is_asm_only(f) return PRESERVE_ALL;
    bpi := get_bpi(f);
    has, ec := fn_entry_count(f);
    if !has { fn_set_entry_count(f, cast(u64) prof_verify_cl.default_function_entry_count); has, ec = fn_entry_count(f); }
    if has && ec == 0 return PRESERVE_ALL;
    changed := false;
    weights_for_test_offset: u32 = 0;
    PRIMES :: u32.[3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71];
    for bb: fn_blocks(f) {
        if prof_verify_cl.annotate_select {
            for i: block_insts(bb) {
                if inst_op(i) != .SELECT continue;
                if is_vector_type(vtype(op(i, 0))) continue;
                if get_metadata(i, md_fixed("prof")) != NONE continue;
                set_branch_weights(i, .[prof_verify_cl.select_true_weight, prof_verify_cl.select_false_weight]);
            }
        }
        term := pv_terminator_benefiting_from_md_prof(bb);
        if term == NONE || get_metadata(term, md_fixed("prof")) != NONE continue;
        n := num_successors(term);
        weights := NewArray(cast(s64) n, u32,, allocator = temp);
        if prof_verify_cl.weights_for_test {
            for k: 0..cast(s64) n - 1 weights[k] = PRIMES[(cast(s64) weights_for_test_offset + k) % PRIMES.count];
            weights_for_test_offset += 1;
        } else {
            // every probability has the denominator 1 << 31, so LCM = 1 << 31 and the weights are N / GCD
            probs := NewArray(cast(s64) n, u32,, allocator = temp);
            for k: 0..cast(s64) n - 1 probs[k] = bpi_edge_probability(bpi, bb, get_successor(term, cast(u32) k));
            g: u64 = 0;
            for probs if it != 0 { g = ifx g == 0 then cast(u64) it else pv_gcd(g, it); }
            assert(g != 0);
            for probs weights[it_index] = cast(u32) (cast(u64) it / g);
        }
        set_branch_weights(term, weights);
        changed = true;
    }
    return ifx changed then PRESERVE_NONE else PRESERVE_ALL;
}

pv_gcd :: (a_in: u64, b_in: u64) -> u64 { a := a_in; b := b_in; while b != 0 { t := a % b; a = b; b = t; } return a; }

// ProfileVerifierPass::run(Module)
prof_verify_run :: () -> Preserved {
    ignore: Table(Value_Id, bool); ignore.allocator = temp;
    populate :: (name: string) #expand {
        ct := module_get_global_variable(name);
        if ct == NONE || is_declaration(ct) return;
        ca := gv_initializer(ct);
        if vkind(ca) != .C_ARRAY return;
        for k: 0..nops(ca) - 1 {
            cs := op(ca, k);
            if vkind(cs) != .C_STRUCT || nops(cs) < 2 continue;
            fv := strip_pointer_casts(op(cs, 1));
            if vkind(fv) == .FUNCTION table_set(*ignore, fv, true);
        }
    }
    populate("llvm.global_ctors");
    populate("llvm.global_dtors");
    for f: ir.m_functions {
        if is_declaration(f) continue;
        if pv_is_asm_only(f) continue;
        if table_contains(*ignore, f) continue;
        has, ec := fn_entry_count(f);
        if !has {
            md := get_metadata(f, md_fixed("prof"));
            explicitly_unknown := md != NONE && md_nops(md) == 2 && md_op(md, 0) != NONE &&
                                  ir.mds[md_op(md, 0)].kind == .STRING && ir.mds[md_op(md, 0)].str == "unknown";
            if !explicitly_unknown { pv_emit_profile_error("function entry count missing (set to 0 if cold)", f); continue; }
        } else if ec == 0 continue;
        for bb: fn_blocks(f) {
            if prof_verify_cl.annotate_select {
                for i: block_insts(bb) {
                    if inst_op(i) != .SELECT continue;
                    if is_vector_type(vtype(op(i, 0))) continue;
                    if get_metadata(i, md_fixed("prof")) != NONE continue;
                    pv_emit_profile_error("select annotation missing", f);
                }
            }
            t := pv_terminator_benefiting_from_md_prof(bb);
            if t != NONE && get_metadata(t, md_fixed("prof")) == NONE pv_emit_profile_error("branch annotation missing", f);
        }
    }
    return PRESERVE_ALL;
}
