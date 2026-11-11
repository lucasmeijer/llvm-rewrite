// LibCallsShrinkWrap: port of llvm/lib/Transforms/Utils/LibCallsShrinkWrap.cpp (checkCandidate,
// performCallDomainErrorOnly, performCallRangeErrorOnly, performCallErrors, generateOneRangeCond,
// generateTwoRangeCond, generateCondForPow, shrinkWrapCI, runImpl) with SplitBlockAndInsertIfThen's DomTreeUpdater
// path (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp). In a strictfp function the compares are
// llvm.experimental.constrained.fcmp calls (IRBuilder::CreateConstrainedFPCmp).

INF_F32 :: 0h7F800000;

// createCond(BBBuilder at CI, Arg, Cmp, float Val)
lcsw_cond :: (ci: Value_Id, arg: Value_Id, pred: u8, val: float32) -> Value_Id {
    v := val;
    bits: u64 = cast(u64) (cast(*u32) *v).*;
    c := const_fp_words(type_simple(.FLOAT), .[bits]);
    if type_kind(vtype(arg)) != .FLOAT {
        w, _ := fp_convert(.FLOAT, type_kind(vtype(arg)), .[bits]);   // ConstantFoldCastInstruction(FPExt)
        c = const_fp_words(vtype(arg), w);
    }
    if fn_has_fn_attr(inst_fn(ci), .StrictFP) {
        // setIsFPConstrained(true): CreateConstrainedFPCmp(experimental_constrained_fcmp, P, Arg, V) with the default
        // exception behavior (fpexcept.strict), then setConstrainedFPCallAttr (strictfp)
        b: Irb; irb_set_before(*b, ci);
        cc := irb_intrinsic(*b, "llvm.experimental.constrained.fcmp", .[vtype(arg)],
                            .[arg, c, md_as_value(md_string(FCMP_PREDS[pred])), md_as_value(md_string("fpexcept.strict"))]);
        call_add_fn_attr(cc, .StrictFP);
        return cc;
    }
    if is_constant_kind(vkind(arg)) {
        fc := cf_compare(pred, arg, c);
        if fc != NONE return fc;
    }
    i := create_fcmp(pred, arg, c);
    insert_at_position(i, inst_block(ci), ci, false);
    copy_debug_loc(i, ci);
    return i;
}
// createOrCond(CI, Arg, Cmp, Val, Arg2, Cmp2, Val2): the second condition is built first
lcsw_or_cond :: (ci: Value_Id, arg: Value_Id, p: u8, v: float32, arg2: Value_Id, p2: u8, v2: float32) -> Value_Id {
    c2 := lcsw_cond(ci, arg2, p2, v2);
    c1 := lcsw_cond(ci, arg, p, v);
    b: Irb; irb_set_before(*b, ci);
    return irb_binop(*b, .OR, c1, c2);
}

lcsw_shrink_wrap :: (ci: Value_Id, cond: Value_Id, dtu: *Dtu) {
    head := inst_block(ci);
    orig_succs: [..] Value_Id; orig_succs.allocator = temp;
    {
        s: [..] Value_Id; s.allocator = temp;
        block_successors(head, *s);
        for x: s { dup := false; for orig_succs if it == x { dup = true; break; } if !dup array_add(*orig_succs, x); }
    }
    br := jt_split_block_and_insert_if_then(cond, ci, NONE);
    aic_unlikely_branch_weights(block_terminator(head));
    call_bb := inst_block(br);
    tail := get_successor(br, 0);
    ups: [..] Dom_Update; ups.allocator = temp;
    array_add(*ups, .{true, head, call_bb});
    array_add(*ups, .{true, head, tail});
    array_add(*ups, .{true, call_bb, tail});
    for orig_succs array_add(*ups, .{true, tail, it});
    for orig_succs array_add(*ups, .{false, head, it});
    dtu_apply(dtu, ups);
    set_name(call_bb, "cdce.call");
    set_name(tail, "cdce.end");
    iv_move_before_head(ci, block_first_insertion_pt(call_bb), call_bb);   // removeFromParent + insertInto(getFirstInsertionPt())
}

lcsw_perform :: (ci: Value_Id, lf: Lib_Func, dtu: *Dtu) -> bool {
    a0 := op(ci, 0);
    INF :: INF_F32;
    cond: Value_Id = NONE;
    // performCallDomainErrorOnly
    if lf == {
        case .acos; #through; case .acosf; #through; case .acosl; #through;
        case .asin; #through; case .asinf; #through; case .asinl;
            cond = lcsw_or_cond(ci, a0, FCMP_OLT, -1.0, a0, FCMP_OGT, 1.0);
        case .cos; #through; case .cosf; #through; case .cosl; #through;
        case .sin; #through; case .sinf; #through; case .sinl;
            cond = lcsw_or_cond(ci, a0, FCMP_OEQ, INF, a0, FCMP_OEQ, -INF);
        case .acosh; #through; case .acoshf; #through; case .acoshl;
            cond = lcsw_cond(ci, a0, FCMP_OLT, 1.0);
        case .sqrt; #through; case .sqrtf; #through; case .sqrtl;
            cond = lcsw_cond(ci, a0, FCMP_OLT, 0.0);
    }
    if cond != NONE { lcsw_shrink_wrap(ci, cond, dtu); return true; }
    // performCallRangeErrorOnly
    lo, hi: float32;
    two := true;
    if lf == {
        case .cosh; #through; case .sinh; lo = -710; hi = 710;
        case .coshf; #through; case .sinhf; lo = -89; hi = 89;
        case .coshl; #through; case .sinhl; lo = -11357; hi = 11357;
        case .exp; lo = -745; hi = 709;
        case .expf; lo = -103; hi = 88;
        case .expl; lo = -11399; hi = 11356;
        case .exp10; lo = -323; hi = 308;
        case .exp10f; lo = -45; hi = 38;
        case .exp10l; lo = -4950; hi = 4932;
        case .exp2; lo = -1074; hi = 1023;
        case .exp2f; lo = -149; hi = 127;
        case .exp2l; lo = -16445; hi = 11383;
        case .expm1; two = false; hi = 709;
        case .expm1f; two = false; hi = 88;
        case .expm1l; two = false; hi = 11356;
        case; two = false; hi = 0;
    }
    is_range := two || lf == .expm1 || lf == .expm1f || lf == .expm1l;
    if is_range {
        if two cond = lcsw_or_cond(ci, a0, FCMP_OGT, hi, a0, FCMP_OLT, lo);
        else cond = lcsw_cond(ci, a0, FCMP_OGT, hi);
        lcsw_shrink_wrap(ci, cond, dtu);
        return true;
    }
    // performCallErrors
    if lf == {
        case .atanh; #through; case .atanhf; #through; case .atanhl;
            cond = lcsw_or_cond(ci, a0, FCMP_OLE, -1.0, a0, FCMP_OGE, 1.0);
        case .log; #through; case .logf; #through; case .logl; #through; case .log10; #through; case .log10f; #through;
        case .log10l; #through; case .log2; #through; case .log2f; #through; case .log2l; #through; case .logb; #through;
        case .logbf; #through; case .logbl;
            cond = lcsw_cond(ci, a0, FCMP_OLE, 0.0);
        case .log1p; #through; case .log1pf; #through; case .log1pl;
            cond = lcsw_cond(ci, a0, FCMP_OLE, -1.0);
        case .pow; #through; case .powf; #through; case .powl;
            cond = lcsw_cond_for_pow(ci, lf);
            if cond == NONE return false;
        case; return false;
    }
    lcsw_shrink_wrap(ci, cond, dtu);
    return true;
}

// generateCondForPow
lcsw_cond_for_pow :: (ci: Value_Id, lf: Lib_Func) -> Value_Id {
    if lf != .pow return NONE;
    base := op(ci, 0); ex := op(ci, 1);
    if vkind(base) == .C_FP {
        d := fp_to_f64(type_kind(vtype(base)), const_fp_value(base));
        if d < 1.0 || d > 255.0 return NONE;
        return lcsw_cond(ci, ex, FCMP_OGT, 127.0);
    }
    if !is_inst(base) return NONE;
    o := inst_op(base);
    if o == .UITOFP || o == .SITOFP {
        bw := type_bits(vtype(op(base, 0)));
        upper: float32;
        if bw == 8 upper = 128;
        else if bw == 16 upper = 64;
        else if bw == 32 upper = 32;
        else return NONE;
        return lcsw_or_cond(ci, base, FCMP_OLE, 0.0, ex, FCMP_OGT, upper);
    }
    return NONE;
}

libcalls_shrinkwrap_run :: (f: Value_Id) -> Preserved {
    if fn_has_fn_attr(f, .OptimizeForSize) || fn_has_fn_attr(f, .MinSize) return PRESERVE_ALL;   // hasOptSize
    dt := cached_domtree(f);
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    t := tli_for(f);
    wl: [..] Value_Id; wl.allocator = temp;
    for i: fn_insts(f) {
        if inst_op(i) != .CALL || call_is_no_builtin(i) || has_uses(i) continue;
        callee := call_called_function(i);
        if callee == NONE continue;
        ok, lf := tli_lookup_fn(callee);
        if !ok || !tli_func_has(t, lf) continue;
        if call_num_args(i) == 0 continue;
        k := type_kind(vtype(op(i, 0)));
        if k != .FLOAT && k != .DOUBLE && k != .X86_FP80 continue;
        array_add(*wl, i);
    }
    changed := false;
    for ci: wl {
        _, lf := tli_lookup_fn(call_called_function(ci));
        if lcsw_perform(ci, lf, *dtu) changed = true;
    }
    dtu_flush(*dtu);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
