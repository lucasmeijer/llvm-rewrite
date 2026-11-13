// Coroutine shape analysis and the helpers shared by the coroutine passes.
// Ported from llvm/lib/Transforms/Coroutines/Coroutines.cpp (coro::Shape::analyze / invalidateCoroutine /
// cleanCoroutine, the ABI init()s, emitAlloc / emitDealloc, the checkWellFormed checks, declaresIntrinsics,
// elideCoroFree, suppressCoroAllocs, LowererBase::makeSubFnCall), llvm/include/llvm/Transforms/Coroutines/CoroShape.h
// and CoroInstr.h (the accessors of the coroutine intrinsics).
//
// coro::Shape is `Coro_Shape` (temp arrays); the C++ union of the per-ABI lowering storages is flattened into
// fields prefixed sw_ / rc_ / as_. coro::BaseABI and its subclasses are just the `abi` tag (switches at the virtual
// calls: coro_abi_init, coro_split_coroutine).

IID_CORO_ALLOC :: #run iid_by_name("llvm.coro.alloc");
IID_CORO_ALIGN :: #run iid_by_name("llvm.coro.align");
IID_CORO_ALLOCA_ALLOC :: #run iid_by_name("llvm.coro.alloca.alloc");
IID_CORO_ALLOCA_FREE :: #run iid_by_name("llvm.coro.alloca.free");
IID_CORO_ALLOCA_GET :: #run iid_by_name("llvm.coro.alloca.get");
IID_CORO_ASYNC_CONTEXT_ALLOC :: #run iid_by_name("llvm.coro.async.context.alloc");
IID_CORO_ASYNC_CONTEXT_DEALLOC :: #run iid_by_name("llvm.coro.async.context.dealloc");
IID_CORO_ASYNC_RESUME :: #run iid_by_name("llvm.coro.async.resume");
IID_CORO_ASYNC_SIZE_REPLACE :: #run iid_by_name("llvm.coro.async.size.replace");
IID_CORO_AWAIT_SUSPEND_BOOL :: #run iid_by_name("llvm.coro.await.suspend.bool");
IID_CORO_AWAIT_SUSPEND_HANDLE :: #run iid_by_name("llvm.coro.await.suspend.handle");
IID_CORO_AWAIT_SUSPEND_VOID :: #run iid_by_name("llvm.coro.await.suspend.void");
IID_CORO_BEGIN :: #run iid_by_name("llvm.coro.begin");
IID_CORO_BEGIN_CUSTOM_ABI :: #run iid_by_name("llvm.coro.begin.custom.abi");
IID_CORO_DEAD :: #run iid_by_name("llvm.coro.dead");
IID_CORO_DESTROY :: #run iid_by_name("llvm.coro.destroy");
IID_CORO_DONE :: #run iid_by_name("llvm.coro.done");
IID_CORO_END :: #run iid_by_name("llvm.coro.end");
IID_CORO_END_ASYNC :: #run iid_by_name("llvm.coro.end.async");
IID_CORO_END_RESULTS :: #run iid_by_name("llvm.coro.end.results");
IID_CORO_FRAME :: #run iid_by_name("llvm.coro.frame");
IID_CORO_FREE :: #run iid_by_name("llvm.coro.free");
IID_CORO_ID :: #run iid_by_name("llvm.coro.id");
IID_CORO_ID_ASYNC :: #run iid_by_name("llvm.coro.id.async");
IID_CORO_ID_RETCON :: #run iid_by_name("llvm.coro.id.retcon");
IID_CORO_ID_RETCON_ONCE :: #run iid_by_name("llvm.coro.id.retcon.once");
IID_CORO_IS_IN_RAMP :: #run iid_by_name("llvm.coro.is_in_ramp");
IID_CORO_NOOP :: #run iid_by_name("llvm.coro.noop");
IID_CORO_PREPARE_ASYNC :: #run iid_by_name("llvm.coro.prepare.async");
IID_CORO_PREPARE_RETCON :: #run iid_by_name("llvm.coro.prepare.retcon");
IID_CORO_PROMISE :: #run iid_by_name("llvm.coro.promise");
IID_CORO_RESUME :: #run iid_by_name("llvm.coro.resume");
IID_CORO_SAVE :: #run iid_by_name("llvm.coro.save");
IID_CORO_SIZE :: #run iid_by_name("llvm.coro.size");
IID_CORO_SUBFN_ADDR :: #run iid_by_name("llvm.coro.subfn.addr");
// IID_CORO_SUSPEND is in pass_licm.jai
IID_CORO_SUSPEND_ASYNC :: #run iid_by_name("llvm.coro.suspend.async");
IID_CORO_SUSPEND_RETCON :: #run iid_by_name("llvm.coro.suspend.retcon");

// CoroSubFnInst::ResumeKind
CORO_SUBFN_RESTART_TRIGGER :: -1;
CORO_SUBFN_RESUME :: 0;
CORO_SUBFN_DESTROY :: 1;
CORO_SUBFN_CLEANUP :: 2;

Coro_Abi :: enum u8 { SWITCH; RETCON; RETCON_ONCE; ASYNC; }

Coro_Shape :: struct {
    coro_begin: Value_Id = NONE;
    coro_ends: [..] Value_Id;
    coro_is_in_ramp_insts: [..] Value_Id;
    coro_sizes: [..] Value_Id;
    coro_aligns: [..] Value_Id;
    coro_suspends: [..] Value_Id;
    coro_await_suspends: [..] Value_Id;
    symmetric_transfers: [..] Value_Id;
    swift_error_ops: [..] Value_Id;

    abi: Coro_Abi;
    frame_align: u64 = 1;
    frame_size: u64;
    frame_ptr: Value_Id = NONE;
    alloca_spill_block: Value_Id = NONE;

    // SwitchLoweringStorage
    sw_resume_switch: Value_Id = NONE;
    sw_promise_alloca: Value_Id = NONE;
    sw_resume_entry_block: Value_Id = NONE;
    sw_index_type: Type_Id = NONE;
    sw_destroy_offset: u64;
    sw_index_align: u64;
    sw_index_offset: u64;
    sw_has_final_suspend: bool;
    sw_has_unwind_coro_end: bool;
    sw_has_coro_elide_no_alloc_variant: bool;

    // RetconLoweringStorage
    rc_resume_prototype: Value_Id = NONE;
    rc_alloc: Value_Id = NONE;
    rc_dealloc: Value_Id = NONE;
    rc_return_block: Value_Id = NONE;
    rc_is_frame_inline_in_storage: bool;

    // AsyncLoweringStorage
    as_context: Value_Id = NONE;
    as_cc: u32;
    as_context_arg_no: u32;
    as_context_header_size: u64;
    as_context_alignment: u64;
    as_frame_offset: u64;
    as_context_size: u64;
    as_async_func_pointer: Value_Id = NONE;
}

coro_shape_init :: (s: *Coro_Shape) {
    s.coro_ends.allocator = temp; s.coro_is_in_ramp_insts.allocator = temp; s.coro_sizes.allocator = temp;
    s.coro_aligns.allocator = temp; s.coro_suspends.allocator = temp; s.coro_await_suspends.allocator = temp;
    s.symmetric_transfers.allocator = temp; s.swift_error_ops.allocator = temp;
}

// RAUW / erase that keep ValueAsMetadata users (debug records) in sync, like Value::replaceAllUsesWith and
// Instruction::eraseFromParent do
coro_rauw :: inline (old: Value_Id, new: Value_Id) { rauw_with_metadata(old, new); }
coro_erase :: inline (i: Value_Id) { erase_inst_with_metadata(i); }

// stripPointerCastsAndAliases
coro_strip_casts_and_aliases :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    while true {
        v = strip_pointer_casts(v);
        if vkind(v) == .ALIAS { v = op(v, 0); continue; }
        return v;
    }
    return v;
}

// coro::declaresIntrinsics (Intrinsic::getDeclarationIfExists for each)
coro_declares_any :: (names: [] string) -> bool {
    for names if module_get_function(it) != NONE return true;
    return false;
}

// coro::declaresAnyIntrinsic (NonOverloadedCoroIntrinsics): CoroConditionalWrapper's condition
coro_declares_any_intrinsic :: () -> bool {
    return coro_declares_any(.["llvm.coro.alloc", "llvm.coro.async.context.alloc", "llvm.coro.async.context.dealloc",
        "llvm.coro.async.resume", "llvm.coro.async.size.replace", "llvm.coro.await.suspend.bool",
        "llvm.coro.await.suspend.handle", "llvm.coro.await.suspend.void", "llvm.coro.begin", "llvm.coro.begin.custom.abi",
        "llvm.coro.destroy", "llvm.coro.done", "llvm.coro.end", "llvm.coro.end.async", "llvm.coro.frame", "llvm.coro.free",
        "llvm.coro.id", "llvm.coro.id.async", "llvm.coro.id.retcon", "llvm.coro.id.retcon.once", "llvm.coro.noop",
        "llvm.coro.prepare.async", "llvm.coro.prepare.retcon", "llvm.coro.promise", "llvm.coro.resume", "llvm.coro.save",
        "llvm.coro.subfn.addr", "llvm.coro.suspend", "llvm.coro.is_in_ramp"]);
}

// coro::isSuspendBlock
coro_is_suspend_block :: (bb: Value_Id) -> bool {
    f := block_first(bb);
    return f != NONE && coro_is_any_suspend(f);
}
coro_is_any_suspend :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_CORO_SUSPEND || id == IID_CORO_SUSPEND_ASYNC || id == IID_CORO_SUSPEND_RETCON;
}
coro_is_any_end :: (i: Value_Id) -> bool { id := call_iid(i); return id == IID_CORO_END || id == IID_CORO_END_ASYNC; }
coro_is_any_id :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_CORO_ID || id == IID_CORO_ID_RETCON || id == IID_CORO_ID_RETCON_ONCE || id == IID_CORO_ID_ASYNC;
}
coro_is_begin :: (i: Value_Id) -> bool { id := call_iid(i); return id == IID_CORO_BEGIN || id == IID_CORO_BEGIN_CUSTOM_ABI; }
coro_is_await_suspend :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_CORO_AWAIT_SUSPEND_VOID || id == IID_CORO_AWAIT_SUSPEND_BOOL || id == IID_CORO_AWAIT_SUSPEND_HANDLE;
}
// Constant::isOneValue for an i1 / integer constant argument
coro_const_is_one :: (v: Value_Id) -> bool { return vkind(v) == .C_INT && !is_vector_type(vtype(v)) && const_int_zext(v) == 1; }

// AnyCoroEndInst
coro_end_is_unwind :: (e: Value_Id) -> bool { return coro_const_is_one(call_arg(e, 1)); }
coro_end_is_fallthrough :: (e: Value_Id) -> bool { return !coro_end_is_unwind(e); }
coro_end_has_results :: (e: Value_Id) -> bool { return call_iid(e) == IID_CORO_END && vkind(call_arg(e, 2)) != .C_TOKEN_NONE; }
coro_end_results :: (e: Value_Id) -> Value_Id { return call_arg(e, 2); }
// CoroAsyncEndInst::getMustTailCallFunction
coro_async_end_must_tail_fn :: (e: Value_Id) -> Value_Id {
    if call_arg_count(e) < 3 return NONE;
    return strip_pointer_casts(call_arg(e, 2));
}
// CoroSuspendInst
coro_suspend_save :: (s: Value_Id) -> Value_Id {
    if call_iid(s) != IID_CORO_SUSPEND return NONE;
    a := call_arg(s, 0);
    if call_iid(a) == IID_CORO_SAVE return a;
    return NONE;
}
coro_suspend_is_final :: (s: Value_Id) -> bool { return coro_const_is_one(call_arg(s, 1)); }
// CoroSuspendAsyncInst
CORO_ASYNC_SUSPEND_STORAGE_ARGNO_ARG :: 0;
CORO_ASYNC_SUSPEND_RESUME_FUNCTION_ARG :: 1;
CORO_ASYNC_SUSPEND_PROJECTION_ARG :: 2;
CORO_ASYNC_SUSPEND_MUST_TAIL_CALL_FUNC_ARG :: 3;
coro_async_suspend_storage_arg_index :: (s: Value_Id) -> u32 { return cast(u32) const_int_zext(call_arg(s, 0)); }
coro_async_suspend_projection_fn :: (s: Value_Id) -> Value_Id { return strip_pointer_casts(call_arg(s, 2)); }
coro_async_suspend_resume_fn :: (s: Value_Id) -> Value_Id { return strip_pointer_casts(call_arg(s, 1)); }
coro_async_suspend_must_tail_fn :: (s: Value_Id) -> Value_Id { return strip_pointer_casts(call_arg(s, 3)); }
// CoroBeginInst
coro_begin_id :: (b: Value_Id) -> Value_Id { return call_arg(b, 0); }
coro_begin_mem :: (b: Value_Id) -> Value_Id { return call_arg(b, 1); }
// CoroIdInst::getInfo: the info argument's global initializer; (outlined parts, resumers)
coro_id_info :: (id: Value_Id) -> (outlined: Value_Id, resumers: Value_Id) {
    gv := strip_pointer_casts(call_arg(id, 3));
    if vkind(gv) != .GLOBAL_VAR return NONE, NONE;
    init := gv_initializer(gv);
    if init != NONE && vkind(init) == .C_STRUCT return init, NONE;
    if init == NONE || vkind(init) != .C_ARRAY fatal("coroutines: the coro.id info global is not a constant array");
    return NONE, init;
}
coro_id_is_post_split :: (id: Value_Id) -> bool { _, r := coro_id_info(id); return r != NONE; }
coro_id_is_pre_split :: (id: Value_Id) -> bool { return !coro_id_is_post_split(id); }
// CoroIdInst::getPromise
coro_id_promise :: (id: Value_Id) -> Value_Id {
    a := call_arg(id, 1);
    if vkind(a) == .C_NULL return NONE;
    return strip_pointer_casts(a);
}
// CoroIdInst::getCoroutine
coro_id_coroutine :: (id: Value_Id) -> Value_Id { return coro_strip_casts_and_aliases(call_arg(id, 2)); }
// AnyCoroIdInst::getCoroAlloc
coro_id_coro_alloc :: (id: Value_Id) -> Value_Id {
    u := ir.v_first_use[id];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) && call_iid(usr) == IID_CORO_ALLOC return usr;
        u = ir.u_next[u];
    }
    return NONE;
}
// AnyCoroIdInst::getCoroBegin
coro_id_coro_begin :: (id: Value_Id) -> Value_Id {
    u := ir.v_first_use[id];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) && coro_is_begin(usr) return usr;
        u = ir.u_next[u];
    }
    fatal("internal: no coro.begin associated with coro.id");
    return NONE;
}
// CoroIdInst::clearPromise
coro_id_clear_promise :: (id: Value_Id) {
    a := call_arg(id, 1);
    set_op(id, 1, const_null(ir.t_ptr));
    if is_inst(a) && inst_op(a) == .ALLOCA return;
    if !is_inst(a) return;
    if !has_uses(a) { coro_erase(a); return; }
    b := coro_id_coro_begin(id);
    inst_move_before_dbg(a, inst_next(b));
}
// AnyCoroIdRetconInst
coro_retcon_storage_size :: (id: Value_Id) -> u64 { return const_int_zext(call_arg(id, 0)); }
coro_retcon_storage_align :: (id: Value_Id) -> u64 { return const_int_zext(call_arg(id, 1)); }
coro_retcon_storage :: (id: Value_Id) -> Value_Id { return call_arg(id, 2); }
coro_retcon_prototype :: (id: Value_Id) -> Value_Id { return coro_strip_casts_and_aliases(call_arg(id, 3)); }
coro_retcon_alloc_fn :: (id: Value_Id) -> Value_Id { return coro_strip_casts_and_aliases(call_arg(id, 4)); }
coro_retcon_dealloc_fn :: (id: Value_Id) -> Value_Id { return coro_strip_casts_and_aliases(call_arg(id, 5)); }
// CoroIdAsyncInst
coro_async_id_storage_arg_index :: (id: Value_Id) -> u32 { return cast(u32) const_int_zext(call_arg(id, 2)); }
coro_async_id_storage :: (id: Value_Id) -> Value_Id { return fn_arg(inst_fn(id), coro_async_id_storage_arg_index(id)); }
coro_async_id_func_pointer :: (id: Value_Id) -> Value_Id { return strip_pointer_casts(call_arg(id, 3)); }

// Shape::getIndex / getSwitchCoroId / getRetconCoroId / getAsyncCoroId
coro_shape_index :: (s: *Coro_Shape, v: u64) -> Value_Id { return const_int(s.sw_index_type, v); }
coro_shape_id :: (s: *Coro_Shape) -> Value_Id { return coro_begin_id(s.coro_begin); }
// Shape::getRetconResultTypes: the coroutine's struct return type minus its first element
coro_retcon_result_types :: (s: *Coro_Shape) -> [] Type_Id {
    rt := func_ret(glob(inst_fn(s.coro_begin)).value_type);
    r: [..] Type_Id; r.allocator = temp;
    if type_kind(rt) == .STRUCT { n := type_nsub(rt); for k: 1..cast(s64) n - 1 array_add(*r, type_sub(rt, cast(u32) k)); }
    return r;
}
// Shape::getRetconResumeTypes: the prototype's parameters minus the first
coro_retcon_resume_types :: (s: *Coro_Shape) -> [] Type_Id {
    ft := glob(s.rc_resume_prototype).value_type;
    r: [..] Type_Id; r.allocator = temp;
    n := func_nparams(ft);
    for k: 1..cast(s64) n - 1 array_add(*r, func_param(ft, cast(u32) k));
    return r;
}
// Shape::getResumeFunctionType (NONE for async: depends on the active suspend)
coro_resume_function_type :: (s: *Coro_Shape) -> Type_Id {
    if s.abi == {
      case .SWITCH; return type_func(ir.t_void, .[ir.t_ptr], false);
      case .RETCON; #through;
      case .RETCON_ONCE; return glob(s.rc_resume_prototype).value_type;
      case .ASYNC; return NONE;
    }
    return NONE;
}
// Shape::getResumeFunctionCC
coro_resume_function_cc :: (s: *Coro_Shape) -> u32 {
    if s.abi == {
      case .SWITCH; return 0;
      case .RETCON; #through;
      case .RETCON_ONCE; return glob(s.rc_resume_prototype).cc;
      case .ASYNC; return s.as_cc;
    }
    return 0;
}
// Shape::getInsertPtAfterFramePtr: (block, instruction, head bit)
coro_insert_pt_after_frame_ptr :: (s: *Coro_Shape) -> (bb: Value_Id, pt: Value_Id, head: bool) {
    if is_inst(s.frame_ptr) return inst_block(s.frame_ptr), inst_next(s.frame_ptr), true;
    e := fn_entry(arg_parent(s.frame_ptr));
    return e, block_first(e), false;
}

// ---------------------------------------------------------------- LowererBase

// LowererBase::makeSubFnCall: CallInst::Create(coro.subfn.addr, {Arg, i8 Index}, "", InsertPt)
coro_make_subfn_call :: (arg: Value_Id, index: s64, insert_pt: Value_Id) -> Value_Id {
    fnc := get_or_insert_intrinsic_declaration(IID_CORO_SUBFN_ADDR);
    b: Irb; irb_set_before(*b, insert_pt); b.dbg = NONE;
    return coro_irb_call_nodbg(*b, fnc, .[arg, const_int(ir.t_i8, cast(u64) index)]);
}
// CallInst::Create(...) at an insertion point: no debug location
coro_irb_call_nodbg :: (b: *Irb, callee: Value_Id, args: [] Value_Id, name := "") -> Value_Id {
    fty := glob(callee).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, callee);
    insert_at_position(i, b.bb, b.pt, b.head);
    if name.count set_name(i, name);
    return i;
}

// ---------------------------------------------------------------- shared lowering helpers

// coro::elideCoroFree
coro_elide_coro_free :: (frame_ptr: Value_Id) {
    frees: [..] Value_Id; frees.allocator = temp;
    deads: [..] Value_Id; deads.allocator = temp;
    u := ir.v_first_use[frame_ptr];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) {
            id := call_iid(usr);
            if id == IID_CORO_FREE array_add(*frees, usr);
            else if id == IID_CORO_DEAD array_add(*deads, usr);
        }
        u = ir.u_next[u];
    }
    repl := const_null(ir.t_ptr);
    for frees { coro_rauw(it, repl); coro_erase(it); }
    for deads coro_erase(it);
}

// coro::suppressCoroAllocs(CoroIdInst *)
coro_suppress_coro_allocs :: (id: Value_Id) {
    allocs: [..] Value_Id; allocs.allocator = temp;
    u := ir.v_first_use[id];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) && call_iid(usr) == IID_CORO_ALLOC array_add(*allocs, usr);
        u = ir.u_next[u];
    }
    f := const_int(ir.t_i1, 0);
    for allocs { coro_rauw(it, f); coro_erase(it); }
}

// createCoroSave
coro_create_coro_save :: (begin: Value_Id, susp: Value_Id) -> Value_Id {
    fnc := get_or_insert_intrinsic_declaration(IID_CORO_SAVE);
    b: Irb; irb_set_before(*b, susp); b.dbg = NONE;
    save := coro_irb_call_nodbg(*b, fnc, .[begin]);
    set_op(susp, 0, save);
    return save;
}

// ---------------------------------------------------------------- Shape

// Shape::analyze
coro_shape_analyze :: (s: *Coro_Shape, f: Value_Id, coro_frames: *[..] Value_Id, unused_saves: *[..] Value_Id) {
    has_final := false;
    has_unwind_end := false;
    final_index: s64 = 0;
    for i: fn_insts(f) {
        if !is_call_base(i) continue;
        if coro_is_await_suspend(i) { array_add(*s.coro_await_suspends, i); continue; }
        if inst_op(i) != .CALL continue;   // IntrinsicInst is a CallInst
        id := call_iid(i);
        if id == {
          case IID_CORO_SIZE; array_add(*s.coro_sizes, i);
          case IID_CORO_ALIGN; array_add(*s.coro_aligns, i);
          case IID_CORO_FRAME; array_add(coro_frames, i);
          case IID_CORO_SAVE; if !has_uses(i) array_add(unused_saves, i);
          case IID_CORO_SUSPEND_ASYNC;
            coro_check_async_context_project_function(coro_async_suspend_projection_fn(i));
            array_add(*s.coro_suspends, i);
          case IID_CORO_SUSPEND_RETCON; array_add(*s.coro_suspends, i);
          case IID_CORO_SUSPEND;
            array_add(*s.coro_suspends, i);
            if coro_suspend_is_final(i) {
                if has_final fatal("Only one suspend point can be marked as final");
                has_final = true;
                final_index = s.coro_suspends.count - 1;
            }
          case IID_CORO_BEGIN; #through;
          case IID_CORO_BEGIN_CUSTOM_ABI;
            cid := coro_begin_id(i);
            if call_iid(cid) == IID_CORO_ID && !coro_id_is_pre_split(cid) continue;
            if s.coro_begin != NONE fatal("coroutine should have exactly one defining @llvm.coro.begin");
            call_add_ret_attr_kind(i, .NonNull);
            call_add_ret_attr_kind(i, .NoAlias);
            call_remove_fn_attr(i, .NoDuplicate);
            s.coro_begin = i;
          case IID_CORO_END_ASYNC; #through;
          case IID_CORO_END;
            array_add(*s.coro_ends, i);
            if id == IID_CORO_END_ASYNC coro_check_async_end(i);
            if coro_end_is_unwind(i) has_unwind_end = true;
            if coro_end_is_fallthrough(i) && id == IID_CORO_END {
                if s.coro_ends.count > 1 {
                    if coro_end_is_fallthrough(s.coro_ends[0]) fatal("Only one coro.end can be marked as fallthrough");
                    last := s.coro_ends.count - 1;
                    s.coro_ends[0], s.coro_ends[last] = s.coro_ends[last], s.coro_ends[0];
                }
            }
          case IID_CORO_IS_IN_RAMP; array_add(*s.coro_is_in_ramp_insts, i);
        }
    }
    if s.coro_begin == NONE return;
    cid := coro_begin_id(s.coro_begin);
    iid := call_iid(cid);
    if iid == IID_CORO_ID {
        s.abi = .SWITCH;
        s.sw_has_final_suspend = has_final;
        s.sw_has_unwind_coro_end = has_unwind_end;
        s.sw_has_coro_elide_no_alloc_variant = false;
        s.sw_resume_switch = NONE;
        s.sw_promise_alloca = coro_id_promise(cid);
        s.sw_resume_entry_block = NONE;
        last := s.coro_suspends.count - 1;
        if has_final && final_index != last
            s.coro_suspends[final_index], s.coro_suspends[last] = s.coro_suspends[last], s.coro_suspends[final_index];
    } else if iid == IID_CORO_ID_ASYNC {
        s.abi = .ASYNC;
        coro_check_async_id(cid);
        s.as_context = coro_async_id_storage(cid);
        s.as_context_arg_no = coro_async_id_storage_arg_index(cid);
        s.as_context_header_size = const_int_zext(call_arg(cid, 0));
        s.as_context_alignment = const_int_zext(call_arg(cid, 1));
        s.as_async_func_pointer = coro_async_id_func_pointer(cid);
        s.as_cc = glob(f).cc;
    } else if iid == IID_CORO_ID_RETCON || iid == IID_CORO_ID_RETCON_ONCE {
        s.abi = ifx iid == IID_CORO_ID_RETCON then Coro_Abi.RETCON else .RETCON_ONCE;
        coro_check_retcon_id(cid);
        s.rc_resume_prototype = coro_retcon_prototype(cid);
        s.rc_alloc = coro_retcon_alloc_fn(cid);
        s.rc_dealloc = coro_retcon_dealloc_fn(cid);
        s.rc_return_block = NONE;
        s.rc_is_frame_inline_in_storage = false;
    } else fatal("coro.begin is not dependent on a coro.id call");
}

// Shape::invalidateCoroutine
coro_shape_invalidate :: (s: *Coro_Shape, f: Value_Id, coro_frames: *[..] Value_Id) {
    poison := const_poison(ir.t_ptr);
    for coro_frames.* { coro_rauw(it, poison); coro_erase(it); }
    coro_frames.count = 0;
    for cs: s.coro_suspends {
        coro_rauw(cs, const_poison(vtype(cs)));
        save := coro_suspend_save(cs);
        if save != NONE coro_erase(save);
        coro_erase(cs);
    }
    s.coro_suspends.count = 0;
    for s.coro_ends change_to_unreachable(it, false, null);
}

// Shape::cleanCoroutine
coro_shape_clean :: (s: *Coro_Shape, coro_frames: *[..] Value_Id, unused_saves: *[..] Value_Id) {
    for coro_frames.* { coro_rauw(it, s.coro_begin); coro_erase(it); }
    coro_frames.count = 0;
    for unused_saves.* coro_erase(it);
    unused_saves.count = 0;
}

// Shape(Function &F)
coro_shape_build :: (s: *Coro_Shape, f: Value_Id) {
    coro_shape_init(s);
    frames: [..] Value_Id; frames.allocator = temp;
    saves: [..] Value_Id; saves.allocator = temp;
    coro_shape_analyze(s, f, *frames, *saves);
    if s.coro_begin == NONE { coro_shape_invalidate(s, f, *frames); return; }
    coro_shape_clean(s, *frames, *saves);
}

// SwitchABI::init / AsyncABI::init / AnyRetconABI::init
coro_abi_init :: (s: *Coro_Shape) {
    if s.abi == {
      case .SWITCH;
        for susp: s.coro_suspends {
            if call_iid(susp) != IID_CORO_SUSPEND fatal("coro.id must be paired with coro.suspend");
            if coro_suspend_save(susp) == NONE coro_create_coro_save(s.coro_begin, susp);
        }
      case .ASYNC;
      case .RETCON; #through;
      case .RETCON_ONCE;
        result_tys := coro_retcon_result_types(s);
        resume_tys := coro_retcon_resume_types(s);
        for susp: s.coro_suspends {
            if call_iid(susp) != IID_CORO_SUSPEND_RETCON fatal("coro.id.retcon.* must be paired with coro.suspend.retcon");
            nv := call_arg_count(susp);
            k: u32 = 0;
            while k < nv && k < result_tys.count {
                src := call_arg(susp, k);
                if vtype(src) != result_tys[k] {
                    if coro_is_bit_castable(vtype(src), result_tys[k]) {
                        b: Irb; irb_set_before(*b, susp); b.dbg = NONE;
                        bc := new_inst(.BITCAST, result_tys[k], 1);
                        set_op(bc, 0, src);
                        insert_at_position(bc, b.bb, b.pt, b.head);
                        set_op(susp, k, bc);
                        k += 1;
                        continue;
                    }
                    fatal("argument to coro.suspend.retcon does not match corresponding prototype function result");
                }
                k += 1;
            }
            if nv != result_tys.count fatal("wrong number of arguments to coro.suspend.retcon");
            rt := vtype(susp);
            srt: [..] Type_Id; srt.allocator = temp;
            if rt == ir.t_void {}
            else if type_kind(rt) == .STRUCT { for x: 0..cast(s64) type_nsub(rt) - 1 array_add(*srt, type_sub(rt, cast(u32) x)); }
            else array_add(*srt, rt);
            if srt.count != resume_tys.count fatal("wrong number of results from coro.suspend.retcon");
            for x: 0..srt.count - 1 if srt[x] != resume_tys[x] fatal("result from coro.suspend.retcon does not match corresponding prototype function param");
        }
    }
}

// CastInst::isBitCastable
coro_is_bit_castable :: (src: Type_Id, dst: Type_Id) -> bool {
    if !is_first_class(src) || !is_first_class(dst) return false;
    if src == dst return true;
    if is_vector_type(src) && is_vector_type(dst) && type_count(src) == type_count(dst) && type_kind(src) == type_kind(dst)
        return coro_is_bit_castable(type_elem(src), type_elem(dst));
    sb := dl_type_size_in_bits_fixed(src);
    db := dl_type_size_in_bits_fixed(dst);
    if sb != db || sb == 0 return false;
    if is_ptr_type(src) != is_ptr_type(dst) return false;
    if type_kind(src) == .X86_AMX || type_kind(dst) == .X86_AMX return false;
    return true;
}
dl_type_size_in_bits_fixed :: (t: Type_Id) -> u64 {
    if is_aggregate(t) return 0;
    if type_kind(t) == .SVECTOR return 0;
    return dl_type_size_bits(t);
}

// CreateIntCast(V, DestTy, isSigned)
coro_irb_int_cast :: (b: *Irb, v: Value_Id, dt: Type_Id, signed: bool, name := "") -> Value_Id {
    st := vtype(v);
    if st == dt return v;
    sw := type_int_width(scalar_type(st)); dw := type_int_width(scalar_type(dt));
    opc: Opcode = ifx sw == dw then Opcode.BITCAST else ifx sw > dw then Opcode.TRUNC else ifx signed then Opcode.SEXT else Opcode.ZEXT;
    return irb_cast(b, opc, v, dt, name);
}

// Shape::emitAlloc
coro_emit_alloc :: (s: *Coro_Shape, b: *Irb, size_in: Value_Id) -> Value_Id {
    if s.abi != .RETCON && s.abi != .RETCON_ONCE fatal("internal: can't allocate memory in this coroutine lowering");
    alloc := s.rc_alloc;
    size := coro_irb_int_cast(b, size_in, func_param(glob(alloc).value_type, 0), false);
    c := irb_call(b, alloc, .[size]);
    inst(c).cc = glob(alloc).cc;
    return c;
}
// Shape::emitDealloc
coro_emit_dealloc :: (s: *Coro_Shape, b: *Irb, ptr_in: Value_Id) {
    if s.abi != .RETCON && s.abi != .RETCON_ONCE fatal("internal: can't deallocate memory in this coroutine lowering");
    dealloc := s.rc_dealloc;
    ptr := irb_bitcast(b, ptr_in, func_param(glob(dealloc).value_type, 0));
    c := irb_call(b, dealloc, .[ptr]);
    inst(c).cc = glob(dealloc).cc;
}

// ---------------------------------------------------------------- well-formedness checks (report_fatal_error)

coro_check_wf_retcon_prototype :: (i: Value_Id, v: Value_Id) {
    f := coro_strip_casts_and_aliases(v);
    if vkind(f) != .FUNCTION fatal("llvm.coro.id.retcon.* prototype not a Function");
    ft := glob(f).value_type;
    if call_iid(i) == IID_CORO_ID_RETCON {
        rt := func_ret(ft);
        ok := false;
        if is_ptr_type(rt) ok = true;
        else if type_kind(rt) == .STRUCT ok = (ir.types[rt].flags & TYF_OPAQUE) == 0 && type_nsub(rt) > 0 && is_ptr_type(type_sub(rt, 0));
        if !ok fatal("llvm.coro.id.retcon prototype must return pointer as first result");
        if rt != func_ret(glob(inst_fn(i)).value_type) fatal("llvm.coro.id.retcon prototype return type must be same ascurrent function return type");
    }
    if func_nparams(ft) == 0 || !is_ptr_type(func_param(ft, 0)) fatal("llvm.coro.id.retcon.* prototype must take pointer as its first parameter");
}
coro_check_wf_alloc :: (v: Value_Id) {
    f := coro_strip_casts_and_aliases(v);
    if vkind(f) != .FUNCTION fatal("llvm.coro.* allocator not a Function");
    ft := glob(f).value_type;
    if !is_ptr_type(func_ret(ft)) fatal("llvm.coro.* allocator must return a pointer");
    if func_nparams(ft) != 1 || !is_int_type(func_param(ft, 0)) fatal("llvm.coro.* allocator must take integer as only param");
}
coro_check_wf_dealloc :: (v: Value_Id) {
    f := coro_strip_casts_and_aliases(v);
    if vkind(f) != .FUNCTION fatal("llvm.coro.* deallocator not a Function");
    ft := glob(f).value_type;
    if func_ret(ft) != ir.t_void fatal("llvm.coro.* deallocator must return void");
    if func_nparams(ft) != 1 || !is_ptr_type(func_param(ft, 0)) fatal("llvm.coro.* deallocator must take pointer as only param");
}
coro_check_retcon_id :: (i: Value_Id) {
    if vkind(call_arg(i, 0)) != .C_INT fatal("size argument to coro.id.retcon.* must be constant");
    if vkind(call_arg(i, 1)) != .C_INT fatal("alignment argument to coro.id.retcon.* must be constant");
    coro_check_wf_retcon_prototype(i, call_arg(i, 3));
    coro_check_wf_alloc(call_arg(i, 4));
    coro_check_wf_dealloc(call_arg(i, 5));
}
coro_check_async_id :: (i: Value_Id) {
    if vkind(call_arg(i, 0)) != .C_INT fatal("size argument to coro.id.async must be constant");
    if vkind(call_arg(i, 1)) != .C_INT fatal("alignment argument to coro.id.async must be constant");
    if vkind(call_arg(i, 2)) != .C_INT fatal("storage argument offset to coro.id.async must be constant");
    if vkind(coro_strip_casts_and_aliases(call_arg(i, 3))) != .GLOBAL_VAR fatal("llvm.coro.id.async async function pointer not a global");
}
coro_check_async_context_project_function :: (f: Value_Id) {
    if vkind(f) != .FUNCTION fatal("internal: llvm.coro.suspend.async projection function is not a function");
    ft := glob(f).value_type;
    if !is_ptr_type(func_ret(ft)) fatal("llvm.coro.suspend.async resume function projection function must return a ptr type");
    if func_nparams(ft) != 1 || !is_ptr_type(func_param(ft, 0)) fatal("llvm.coro.suspend.async resume function projection function must take one ptr type as parameter");
}
coro_check_async_end :: (e: Value_Id) {
    mt := coro_async_end_must_tail_fn(e);
    if mt == NONE return;
    if func_nparams(glob(mt).value_type) != call_arg_count(e) - 3
        fatal("llvm.coro.end.async must tail call function argument type must match the tail arguments");
}

// ---------------------------------------------------------------- attribute editing

coro_fn_remove_param_attr :: (f: Value_Id, k: u32, kind: Attr_Kind) {
    l := glob(f).attrs;
    s := attr_list_param(l, k);
    if !attr_set_has(s, kind) return;
    glob(f).attrs = attr_list_with_set_at(l, cast(s64) k, attr_set_remove(s, kind));
}
coro_fn_remove_ret_attr :: (f: Value_Id, kind: Attr_Kind) {
    l := glob(f).attrs;
    s := attr_list_ret(l);
    if !attr_set_has(s, kind) return;
    glob(f).attrs = attr_list_with_set_at(l, ATTR_IDX_RET, attr_set_remove(s, kind));
}
coro_fn_remove_fn_attr :: (f: Value_Id, kind: Attr_Kind) {
    l := glob(f).attrs;
    s := attr_list_fn(l);
    if !attr_set_has(s, kind) return;
    glob(f).attrs = attr_list_with_fn(l, attr_set_remove(s, kind));
}

// ---------------------------------------------------------------- small IR helpers

// MDString::getIfExists
md_string_if_exists :: (s: string) -> Md_Id {
    k := *md_key; key_reset(k); key_u8(k, 0); key_str(k, s);
    found, id := table_find(*ir.md_map, key_view(k));
    if found return id;
    return NONE;
}
// MDNode::getIfExists (a uniqued tuple)
md_tuple_if_exists :: (ops: [] Md_Id) -> Md_Id {
    k := *md_key; key_reset(k); key_u8(k, 2);
    for ops key_u32(k, it);
    found, id := table_find(*ir.md_map, key_view(k));
    if found return id;
    return NONE;
}
// CatchSwitchInst::setUnwindDest / CleanupReturnInst::setUnwindDest for a terminator that already unwinds to a block
coro_set_eh_unwind_dest :: (ti: Value_Id, succ: Value_Id) {
    if inst_op(ti) == .CLEANUPRET {
        if nops(ti) < 2 fatal("coro-split: giving an unwind destination to a cleanupret that unwinds to the caller is not supported yet");
        set_op(ti, 1, succ);
        return;
    }
    if (inst(ti).flags & F_HAS_UNWIND) == 0 fatal("coro-split: giving an unwind destination to a catchswitch that unwinds to the caller is not supported yet");
    set_op(ti, 1, succ);
}
// dwarf::isCPlusPlus(DICompileUnit::getSourceLanguage().getUnversionedName())
coro_di_lang_is_cplusplus :: (cu: Md_Id) -> bool {
    l := di_int(cu, 0);
    return l == 0x04 || l == 0x19 || l == 0x1a || l == 0x21 || l == 0x2a || l == 0x2b;
}
inst_parent_fn :: (i: Value_Id) -> Value_Id { if inst_block(i) == NONE return NONE; return inst_fn(i); }
