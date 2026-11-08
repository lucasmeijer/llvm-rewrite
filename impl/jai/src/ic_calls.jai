// InstCombine: visitCallInst (the generic intrinsics), visitCallBase, visitInvokeInst, visitCallBrInst,
// visitFenceInst and their helpers.
// Ported from: llvm/lib/Transforms/InstCombine/InstCombineCalls.cpp (LLVM 23.1.5), in the file's order.

// ---------------------------------------------------------------- AA (InstCombinerImpl::AA)

ic_aar_state: struct { f: Value_Id = NONE; r: Aa_Results; }
// the function's AAResults (AM.getResult<AAManager>(F)); InstCombine preserves the CFG so one per function run
ic_aa :: () -> *Aa_Results {
    if ic_aar_state.f != ic.f { ic_aar_state.r = aa_results_for(ic.f); ic_aar_state.f = ic.f; }
    return *ic_aar_state.r;
}
// AA->getModRefInfoMask(Ptr) (MemoryLocation::getBeforeOrAfter(Ptr), IgnoreLocals = false)
ic_points_to_const_mem_mask :: (ptr: Value_Id) -> u8 {
    return aa_mod_ref_mask(aa_query_new(ic_aa()), mloc_before_or_after(ptr));
}

// visitCallInst: InstSimplify (calls with uses), the nounwind inference. Not ported: everything after.
ic_visit_call :: (i: Value_Id) -> Value_Id {
    if has_uses(i) {
        args: [..] Value_Id; args.allocator = temp;
        n := call_num_args(i);
        if n > 0 for k: 0..n-1 array_add(*args, op(i, k));
        v := simplify_call(i, call_callee(i), args, ic_q(i));
        if v != NONE return ic_replace_inst_uses_with(i, v);
    }
    if get_freed_operand(i) != NONE fatal("instcombine: visitFree is not supported yet");
    if fn_has_fn_attr(ic.f, .NoUnwind) && !call_has_fn_attr(i, .NoUnwind) {
        call_add_fn_attr(i, .NoUnwind);
        return i;
    }
    return NONE;
}
