// CoroCleanup: lowers the coroutine intrinsics that remain after CoroSplit (coro.begin / coro.free / coro.id /
// coro.alloc / coro.subfn.addr / coro.noop / coro.async.*), then runs SimplifyCFG on every changed function.
// Ported from llvm/lib/Transforms/Coroutines/CoroCleanup.cpp (Lowerer, NoopCoroElider as a PtrUseVisitor walk,
// buildDebugInfoForNoopResumeDestroyFunc) and Function::createWithDefaultAttr (llvm/lib/IR/Function.cpp).

// lowerSubFn
coro_cleanup_lower_subfn :: (subfn: Value_Id) {
    b: Irb; irb_set_before(*b, subfn);
    frame_ptr := call_arg(subfn, 0);
    index := cast(s64) const_int_sext(call_arg(subfn, 1));
    frame_ty := type_literal_struct(.[ir.t_ptr, ir.t_ptr], false);
    gep := irb_gep(*b, frame_ty, frame_ptr, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, cast(u64) index)], "", F_INBOUNDS);
    ld := irb_load(*b, ir.t_ptr, gep, dl_abi_align(ir.t_ptr));
    coro_rauw(subfn, ld);
}

// Function::createWithDefaultAttr
fn_create_with_default_attr :: (ft: Type_Id, linkage: Linkage, name: string, as: u32 = 0) -> Value_Id {
    f := new_function(ft, "", as);
    gv_set_linkage(f, linkage);
    array_add(*ir.m_functions, f);
    if name.count set_name(f, name);
    items: [..] Attr; items.allocator = temp;
    flag_int :: (key: string) -> u64, bool {
        m := module_flag(key);
        if m == NONE || ir.mds[m].kind != .VALUE return 0, false;
        v := ir.mds[m].value;
        if vkind(v) != .C_INT return 0, false;
        return const_int_zext(v), true;
    }
    uw, _ := flag_int("uwtable");
    if uw != 0 { a: Attr; a.kind = .UWTable; a.ty = NONE; a.ival = uw; array_add(*items, a); }
    fp, _ := flag_int("frame-pointer");
    fps := "";
    if fp == 1 fps = "non-leaf"; else if fp == 2 fps = "all"; else if fp == 3 fps = "reserved"; else if fp == 4 fps = "non-leaf-no-reserve";
    if fps.count { a: Attr; a.kind = .STRING_ATTR; a.ty = NONE; a.key = "frame-pointer"; a.val = fps; array_add(*items, a); }
    if module_flag("function_return_thunk_extern") != NONE { a: Attr; a.kind = .FnRetThunkExtern; a.ty = NONE; array_add(*items, a); }
    set :: (key: string) -> bool { v, ok := flag_int(key); return ok && v != 0; }
    sign := "none";
    if set("sign-return-address") sign = "non-leaf";
    if set("sign-return-address-all") sign = "all";
    if sign != "none" {
        a: Attr; a.kind = .STRING_ATTR; a.ty = NONE; a.key = "sign-return-address"; a.val = sign; array_add(*items, a);
        b: Attr; b.kind = .STRING_ATTR; b.ty = NONE; b.key = "sign-return-address-key";
        b.val = ifx set("sign-return-address-with-bkey") then "b_key" else "a_key"; array_add(*items, b);
    }
    for key: string.["branch-target-enforcement", "branch-protection-pauth-lr", "guarded-control-stack", "ptrauth-returns",
                     "ptrauth-auth-traps", "ptrauth-indirect-gotos", "aarch64-jump-table-hardening"] {
        if set(key) { a: Attr; a.kind = .STRING_ATTR; a.ty = NONE; a.key = key; a.val = ""; array_add(*items, a); }
    }
    if items.count glob(f).attrs = attr_list_with_fn(glob(f).attrs, attr_set_get(items));
    return f;
}

// the first DICompileUnit of !llvm.dbg.cu (M.debug_compile_units_begin())
module_first_debug_cu :: () -> Md_Id {
    for * ir.named_md if it.name == "llvm.dbg.cu" && it.ops.count > 0 return it.ops[0];
    return NONE;
}

DI_SPFLAG_DEFINITION :: 8;

// DIBuilder::createSubroutineType(getOrCreateTypeArray(types))
dib_subroutine_type :: (types: [] Md_Id, flags: u64 = 0) -> Md_Id {
    return di_get(.SUBROUTINE_TYPE, false, .[NONE, NONE, NONE, NONE, NONE, md_tuple(types, false)], .[flags, 0]);
}
// MDString::get canonicalized like DIBuilder (empty string = null)
dib_str :: (s: string) -> Md_Id { if s.count == 0 return NONE; return md_string(s); }

// buildDebugInfoForNoopResumeDestroyFunc
coro_build_noop_debug_info :: (noop_fn: Value_Id) {
    cu := module_first_debug_cu();
    if cu == NONE return;
    st := dib_subroutine_type(.[NONE, NONE]);
    name := vname(noop_fn);
    // DIBuilder::createFunction(CU, Name, LinkageName, CU->getFile(), 0, Ty, 0, FlagArtificial, SPFlagDefinition):
    // distinct, scope getNonCompileUnitScope(CU) = null, unit = CU (definition)
    sp := di_get(.SUBPROGRAM, true, .[di_op(cu, 0), NONE, dib_str(name), dib_str(name), st, cu, NONE, NONE, NONE, NONE, NONE, NONE, NONE],
                 .[0, 0, 0, 0, DI_FLAG_ARTIFICIAL, DI_SPFLAG_DEFINITION, 0]);
    set_metadata(noop_fn, MDK_DBG, sp);
}

Coro_Cleanup :: struct {
    noop_coro: Value_Id = NONE;
}

// Lowerer::lowerCoroNoop
coro_cleanup_lower_coro_noop :: (l: *Coro_Cleanup, ii: Value_Id) {
    if l.noop_coro == NONE {
        fty := type_func(ir.t_void, .[ir.t_ptr], false);
        frame_ty := type_named_struct("");
        set_struct_body(frame_ty, .[ir.t_ptr, ir.t_ptr], false);
        ctx_set_struct_name(frame_ty, "NoopCoro.Frame");
        noop_fn := fn_create_with_default_attr(fty, .INTERNAL, "__NoopCoro_ResumeDestroy");
        coro_build_noop_debug_info(noop_fn);
        entry := create_block(noop_fn, "entry");
        ret := new_inst(.RET, ir.t_void, 0);
        block_append_inst(entry, ret);
        c := const_aggregate(.C_STRUCT, frame_ty, .[noop_fn, noop_fn]);
        l.noop_coro = gv_create(frame_ty, true, .PRIVATE, c, "NoopCoro.Frame.Const", NONE, 0, 0);
        glob(l.noop_coro).sanitizer = 1 | 2;   // setNoSanitizeMetadata
    }
    coro_rauw(ii, l.noop_coro);   // CreateBitCast(NoopCoro, ptr) folds to NoopCoro
}

// NoopCoroElider (a PtrUseVisitor over the uses of a coro.noop result)
Noop_Elider :: struct {
    worklist: [..] Use_Id;
    visited: Table(Use_Id, bool);
}

noop_enqueue_users :: (e: *Noop_Elider, v: Value_Id) {
    u := ir.v_first_use[v];
    while u != NONE {
        if !table_contains(*e.visited, u) { table_set(*e.visited, u, true); array_add(*e.worklist, u); }
        u = ir.u_next[u];
    }
}
// eraseFromWorklist
noop_erase_from_worklist :: (e: *Noop_Elider, i: Value_Id) {
    k := 0;
    for e.worklist if ir.u_user[it] != i { e.worklist[k] = it; k += 1; }
    e.worklist.count = k;
}
// tryEraseCallInvoke
noop_try_erase_call_invoke :: (e: *Noop_Elider, i: Value_Id) -> bool {
    if inst_op(i) == .CALL {
        noop_erase_from_worklist(e, i);
        coro_erase(i);
        return true;
    }
    if inst_op(i) == .INVOKE {
        b: Irb; irb_set_before(*b, i);
        normal := get_successor(i, 0);
        unwind := get_successor(i, 1);
        irb_insert(*b, create_br(normal));
        noop_erase_from_worklist(e, i);
        block_remove_predecessor(unwind, inst_block(i));
        coro_erase(i);
        return true;
    }
    return false;
}
// RecursivelyDeleteTriviallyDeadInstructions(V, nullptr, nullptr, AboutToDeleteCallback = eraseFromWorklist)
noop_recursively_delete_dead :: (e: *Noop_Elider, v: Value_Id) {
    dead_no_tli :: (i: Value_Id) -> bool { return !has_uses(i) && would_instruction_be_trivially_dead(i, false); }
    if !is_inst(v) || !dead_no_tli(v) return;
    dead: [..] Value_Id; dead.allocator = temp;
    array_add(*dead, v);
    while dead.count {
        i := pop(*dead);
        if vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        noop_erase_from_worklist(e, i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o != NONE && !has_uses(o) && is_inst(o) && dead_no_tli(o) array_add(*dead, o);
        }
        erase_inst_with_metadata(i);
    }
}
// NoopCoroElider::run(II): visitPtr(*II) with the overridden visitors
noop_elider_run :: (ii: Value_Id) {
    e: Noop_Elider;
    e.worklist.allocator = temp; e.visited.allocator = temp;
    noop_enqueue_users(*e, ii);
    while e.worklist.count {
        u := pop(*e.worklist);
        i := ir.u_user[u];
        if !is_inst(i) continue;
        o := inst_op(i);
        if o == .LOAD { noop_enqueue_users(*e, i); continue; }   // visitLoadInst
        if o == .BITCAST || o == .ADDRSPACECAST { noop_enqueue_users(*e, i); continue; }
        if o == .GEP { if has_uses(i) noop_enqueue_users(*e, i); continue; }
        if !is_call_base(i) continue;
        id := call_iid(i);
        if id != NOT_INTRINSIC && o == .CALL {
            // visitIntrinsicInst (memory intrinsics go to PtrUseVisitor::visitMemIntrinsic: nothing)
            if is_mem_intrinsic_id(id) continue;
            if id == IID_CORO_SUBFN_ADDR {
                usr := unique_undroppable_user(i);
                if usr == NONE fatal("internal: coro-cleanup: broken module (coro.subfn.addr without a unique user)");
                if !noop_try_erase_call_invoke(*e, usr) continue;
                noop_erase_from_worklist(*e, i);
                coro_erase(i);
            }
            continue;
        }
        // visitCallBase
        v := ir.u_val[u];
        if u == op_use(i, nops(i) - 1) {
            noop_try_erase_call_invoke(*e, i);
            noop_recursively_delete_dead(*e, v);
        }
    }
}
is_mem_intrinsic_id :: (id: Intrinsic_Id) -> bool {
    return id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMCPY_INLINE || id == IID_MEMSET_INLINE;
}

// Lowerer::lower
coro_cleanup_lower :: (l: *Coro_Cleanup, f: Value_Id) -> bool {
    is_private_and_unprocessed := fn_has_fn_attr(f, .PresplitCoroutine) && gv_has_local_linkage(f);
    changed := false;
    dead: [..] Value_Id; dead.allocator = temp;
    for i: fn_insts(f) {
        if !is_inst(i) || inst_op(i) != .CALL continue;
        id := call_iid(i);
        if id == NOT_INTRINSIC continue;
        if id == {
          case IID_CORO_BEGIN; #through;
          case IID_CORO_BEGIN_CUSTOM_ABI; coro_rauw(i, call_arg(i, 1));
          case IID_CORO_FREE; coro_rauw(i, call_arg(i, 1));
          case IID_CORO_DEAD;
          case IID_CORO_ALLOC; coro_rauw(i, const_int(ir.t_i1, 1));
          case IID_CORO_ASYNC_RESUME; coro_rauw(i, const_null(vtype(i)));
          case IID_CORO_ID; #through;
          case IID_CORO_ID_RETCON; #through;
          case IID_CORO_ID_RETCON_ONCE; #through;
          case IID_CORO_ID_ASYNC; coro_rauw(i, const_token_none());
          case IID_CORO_NOOP;
            noop_elider_run(i);
            if has_uses(i) coro_cleanup_lower_coro_noop(l, i);
          case IID_CORO_SUBFN_ADDR; coro_cleanup_lower_subfn(i);
          case IID_CORO_SUSPEND_RETCON; #through;
          case IID_CORO_IS_IN_RAMP;
            if !is_private_and_unprocessed continue;
            coro_rauw(i, const_poison(vtype(i)));
          case IID_CORO_ASYNC_SIZE_REPLACE;
            target := gv_initializer(coro_strip_casts_and_aliases(call_arg(i, 0)));
            source := gv_initializer(coro_strip_casts_and_aliases(call_arg(i, 1)));
            target_size := op(target, 1);
            source_size := op(source, 1);
            if target_size != source_size {
                nfp := const_aggregate(.C_STRUCT, vtype(target), .[op(target, 0), source_size]);
                replace_all_uses_with(target, nfp);
            }
          case; continue;
        }
        for dead if it == i { i = NONE; break; }
        if i != NONE array_add(*dead, i);
        changed = true;
    }
    for dead coro_erase(it);
    return changed;
}

// CoroCleanupPass::run
coro_cleanup_run :: () -> Preserved {
    if !coro_declares_any(.["llvm.coro.alloc", "llvm.coro.begin", "llvm.coro.subfn.addr", "llvm.coro.free",
                            "llvm.coro.dead", "llvm.coro.id", "llvm.coro.id.retcon", "llvm.coro.id.async",
                            "llvm.coro.id.retcon.once", "llvm.coro.noop", "llvm.coro.async.size.replace",
                            "llvm.coro.async.resume", "llvm.coro.begin.custom.abi"]) return PRESERVE_ALL;
    l: Coro_Cleanup;
    // functions created while lowering (the noop resume/destroy function) are visited too
    k := 0;
    while k < ir.m_functions.count {
        f := ir.m_functions[k];
        k += 1;
        if vkind(f) != .FUNCTION continue;
        if coro_cleanup_lower(*l, f) {
            fam_invalidate(f, preserved_cfg());
            node: Pass_Node; node.name = "simplifycfg";
            pa := simplifycfg_run(*node, f);
            fam_invalidate(f, pa);
        }
    }
    return PRESERVE_NONE;
}
