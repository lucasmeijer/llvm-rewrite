// CoroEarly: lowers the coroutine intrinsics that are not needed by later passes (coro.resume / coro.destroy to
// indirect calls through coro.subfn.addr, coro.promise to a GEP, coro.done to a load + compare) and marks the
// coroutine intrinsics that must not be duplicated.
// Ported from llvm/lib/Transforms/Coroutines/CoroEarly.cpp.

// Lowerer::lowerResumeOrDestroy
coro_early_lower_resume_or_destroy :: (cb: Value_Id, index: s64) {
    addr := coro_make_subfn_call(call_arg(cb, 0), index, cb);
    set_op(cb, nops(cb) - 1, addr);   // CB.setCalledOperand(ResumeAddr)
}

// Lowerer::lowerCoroPromise
coro_early_lower_coro_promise :: (intrin: Value_Id) {
    operand := call_arg(intrin, 0);
    alignment := const_int_zext(call_arg(intrin, 1));
    sample := type_literal_struct(.[ir.t_ptr, ir.t_ptr, ir.t_i8], false);
    offset := cast(s64) align_to(dl_struct_offset(sample, 2), max(alignment, 1));
    if coro_const_is_one(call_arg(intrin, 2)) offset = -offset;
    b: Irb; irb_set_before(*b, intrin);
    repl := irb_gep(*b, ir.t_i8, operand, .[const_int(ir.t_i32, cast(u64) offset)], "", F_INBOUNDS);
    coro_rauw(intrin, repl);
    coro_erase(intrin);
}

// Lowerer::lowerCoroDone
coro_early_lower_coro_done :: (ii: Value_Id) {
    operand := call_arg(ii, 0);
    b: Irb; irb_set_before(*b, ii);
    ld := irb_load(*b, ir.t_ptr, operand, dl_abi_align(ir.t_ptr));
    cond := irb_icmp(*b, ICMP_EQ, ld, const_null(ir.t_ptr));
    coro_rauw(ii, cond);
    coro_erase(ii);
}

// Lowerer::lowerEarlyIntrinsics
coro_early_lower_function :: (f: Value_Id) {
    coro_id: Value_Id = NONE;
    coro_begin: Value_Id = NONE;
    frees: [..] Value_Id; frees.allocator = temp;
    has_suspend := false;
    for :early_inc i: fn_insts(f) {
        if !is_call_base(i) continue;
        id := call_iid(i);
        if id == {
          case IID_CORO_BEGIN; #through;
          case IID_CORO_BEGIN_CUSTOM_ABI;
            if coro_begin != NONE fatal("coroutine should have exactly one defining @llvm.coro.begin");
            coro_begin = i;
          case IID_CORO_FREE; array_add(*frees, i);
          case IID_CORO_SUSPEND;
            if coro_suspend_is_final(i) call_add_fn_attr(i, .NoDuplicate);
            has_suspend = true;
          case IID_CORO_END_ASYNC; #through;
          case IID_CORO_END;
            if coro_end_is_fallthrough(i) call_add_fn_attr(i, .NoDuplicate);
          case IID_CORO_ID;
            if coro_id_is_pre_split(i) {
                // setCannotDuplicate(CII): every coro.begin user
                u := ir.v_first_use[i];
                while u != NONE {
                    usr := ir.u_user[u];
                    if is_inst(usr) && coro_is_begin(usr) call_add_fn_attr(usr, .NoDuplicate);
                    u = ir.u_next[u];
                }
                set_op(i, 2, f);   // setCoroutineSelf
                coro_id = i;
            }
          case IID_CORO_ID_RETCON; #through;
          case IID_CORO_ID_RETCON_ONCE; #through;
          case IID_CORO_ID_ASYNC;
            fn_add_fn_attr_kind(f, .PresplitCoroutine);
          case IID_CORO_RESUME; coro_early_lower_resume_or_destroy(i, CORO_SUBFN_RESUME);
          case IID_CORO_DESTROY; coro_early_lower_resume_or_destroy(i, CORO_SUBFN_DESTROY);
          case IID_CORO_PROMISE; coro_early_lower_coro_promise(i);
          case IID_CORO_DONE; coro_early_lower_coro_done(i);
        }
    }
    if coro_id != NONE for frees set_op(it, 0, coro_id);
    if has_suspend {
        na := glob(f).nargs;
        for k: 0..cast(s64) na - 1 coro_fn_remove_param_attr(f, cast(u32) k, .NoAlias);
    }
}

// CoroEarlyPass::run
coro_early_run :: () -> Preserved {
    // coro_suspend omitted as it is overloaded
    if !coro_declares_any(.["llvm.coro.id", "llvm.coro.id.retcon", "llvm.coro.id.retcon.once", "llvm.coro.id.async",
                            "llvm.coro.destroy", "llvm.coro.done", "llvm.coro.end", "llvm.coro.end.async",
                            "llvm.coro.free", "llvm.coro.promise", "llvm.coro.resume"]) return PRESERVE_ALL;
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for fns coro_early_lower_function(it);
    return preserved_cfg();
}
