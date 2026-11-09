// WarnMissedTransformations: port of llvm/lib/Transforms/Scalar/WarnMissedTransforms.cpp, with hasVectorizeTransformation,
// hasDistributeTransformation, getOptionalElementCountLoopAttribute and getLoopVectorizeKindPrefix from
// llvm/lib/Transforms/Utils/LoopUtils.cpp. The DiagnosticInfoOptimizationFailure warnings go to stderr the way the
// default diagnostic handler prints them ("warning: <file>:<line>:<col>: <message>"). The IR never changes.

tw_has_vectorize_transformation :: (li: *Loop_Info, l: Loop_Id) -> s64 {
    has_enable, enable := li_optional_bool_loop_attribute(li, l, "llvm.loop.vectorize.enable");
    if has_enable && !enable return TM_SUPPRESSED_BY_USER;
    has_w, w, scalable := tw_element_count_attribute(li, l);
    has_ic, ic := li_optional_int_loop_attribute(li, l, "llvm.loop.interleave.count");
    w_scalar := has_w && !scalable && w == 1;
    w_vector := has_w && ((scalable && w != 0) || w > 1);
    if has_enable && enable && w_scalar && has_ic && ic == 1 return TM_SUPPRESSED_BY_USER;
    if li_get_boolean_loop_attribute(li, l, "llvm.loop.isvectorized") return TM_DISABLE;
    if has_enable && enable return TM_FORCED_BY_USER;
    if w_scalar && has_ic && ic == 1 return TM_DISABLE;
    if w_vector || (has_ic && ic > 1) return TM_ENABLE;
    if li_has_disable_all_transforms_hint(li, l) return TM_DISABLE;
    return TM_UNSPECIFIED;
}
tw_has_distribute_transformation :: (li: *Loop_Info, l: Loop_Id) -> s64 {
    if li_get_boolean_loop_attribute(li, l, "llvm.loop.distribute.enable") return TM_FORCED_BY_USER;
    if li_has_disable_all_transforms_hint(li, l) return TM_DISABLE;
    return TM_UNSPECIFIED;
}
// getOptionalElementCountLoopAttribute: (present, min, scalable)
tw_element_count_attribute :: (li: *Loop_Info, l: Loop_Id) -> (bool, s64, bool) {
    has_w, w := li_optional_int_loop_attribute(li, l, "llvm.loop.vectorize.width");
    if !has_w return false, 0, false;
    has_s, s := li_optional_int_loop_attribute(li, l, "llvm.loop.vectorize.scalable.enable");
    return true, cast(s64) cast,trunc(u32) w, has_s && s != 0;
}
tw_vectorize_kind_prefix :: (li: *Loop_Info, l: Loop_Id) -> string {
    body := li_get_boolean_loop_attribute(li, l, "llvm.loop.vectorize.body");
    epi := li_get_boolean_loop_attribute(li, l, "llvm.loop.vectorize.epilogue");
    if body && epi return "vectorized epilogue ";
    if body return "vectorized ";
    if epi return "epilogue ";
    return "";
}

// DiagnosticInfoOptimizationFailure printed by the default handler
tw_warn :: (li: *Loop_Info, l: Loop_Id, msg: string) {
    file := "<unknown>"; line: u64 = 0; col: u64 = 0;
    loc := li_start_loc(li, l);
    if loc != NONE {
        line = di_int(loc, 0); col = di_int(loc, 1);
        scope := di_op(loc, 0);
        f := ifx is_di(scope, .FILE) then scope else di_op(scope, 0);
        if f != NONE file = md_str_of(di_op(f, 0));
    }
    print_stderr("warning: %:%:%: %\n", file, line, col, msg);
}

TW_TAIL :: "the optimizer was unable to perform the requested transformation; the transformation might be disabled or specified as part of an unsupported transformation ordering";

tw_warn_about_leftover_transformations :: (li: *Loop_Info, l: Loop_Id) {
    if li_has_unroll_transformation(li, l) == TM_FORCED_BY_USER
        tw_warn(li, l, tconcat(tw_vectorize_kind_prefix(li, l), "loop not unrolled: ", TW_TAIL));
    if li_has_unroll_and_jam_transformation(li, l) == TM_FORCED_BY_USER
        tw_warn(li, l, tconcat("loop not unroll-and-jammed: ", TW_TAIL));
    if tw_has_vectorize_transformation(li, l) == TM_FORCED_BY_USER {
        has_w, w, scalable := tw_element_count_attribute(li, l);
        has_ic, ic := li_optional_int_loop_attribute(li, l, "llvm.loop.interleave.count");
        if !has_w || (scalable && w != 0) || w > 1 tw_warn(li, l, tconcat("loop not vectorized: ", TW_TAIL));
        else if (ifx has_ic then ic else 0) != 1 tw_warn(li, l, tconcat("loop not interleaved: ", TW_TAIL));
    }
    if tw_has_distribute_transformation(li, l) == TM_FORCED_BY_USER
        tw_warn(li, l, tconcat("loop not distributed: ", TW_TAIL));
}

transform_warning_run :: (f: Value_Id) -> Preserved {
    if fn_has_fn_attr(f, .OptimizeNone) return PRESERVE_ALL;
    li := get_loop_info(f);
    pre: [..] Loop_Id; pre.allocator = temp;
    li_loops_in_preorder(li, *pre);
    for pre tw_warn_about_leftover_transformations(li, it);
    return PRESERVE_ALL;
}
