// MakeGuardsExplicitPass: a port of llvm/lib/Transforms/Scalar/MakeGuardsExplicit.cpp and of
// makeGuardControlFlowExplicit (llvm/lib/Transforms/Utils/GuardUtils.cpp), with the SplitBlockAndInsertIfThen
// (Unreachable = true, no DT/LI) it uses (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp).

mge_predicate_pass_branch_weight: u32 = 1 << 20;   // -guards-predicate-pass-branch-weight

// makeGuardControlFlowExplicit(DeoptIntrinsic, Guard, UseWC)
make_guard_control_flow_explicit :: (deopt_fn: Value_Id, guard: Value_Id, use_wc: bool) {
    f := inst_fn(guard);
    // OperandBundleDef DeoptOB(*Guard->getOperandBundle(OB_deopt))
    deopt_inputs: [..] Value_Id; deopt_inputs.allocator = temp;
    nb := call_num_bundles(guard);
    found := false;
    if nb > 0 for k: 0..nb-1 {
        if call_bundle_tag(guard, k) != "deopt" continue;
        b, e := call_bundle_range(guard, k);
        for x: b..e-1 array_add(*deopt_inputs, op(guard, x));
        found = true;
        break;
    }
    assert(found, "guard without a deopt bundle");
    args: [..] Value_Id; args.allocator = temp;
    na := call_arg_count(guard);
    for x: 1..cast(s64) na - 1 array_add(*args, call_arg(guard, cast(u32) x));
    check_bb := inst_block(guard);

    // SplitBlockAndInsertIfThen(Guard->getArgOperand(0), Guard, /*Unreachable*/ true)
    cond := call_arg(guard, 0);
    tail := split_basic_block(check_bb, guard, "");
    then_bb := create_block(f, "", tail);
    deopt_term := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(then_bb, deopt_term);
    copy_debug_loc_or_clear(deopt_term, guard);
    old := block_terminator(check_bb);
    check_bi := create_cond_br(cond, then_bb, tail);
    if get_metadata(check_bi, 0) == NONE copy_debug_loc(check_bi, old);   // ReplaceInstWithInst
    insert_at_position(check_bi, check_bb, old, false);
    drop_all_references(old);
    erase_inst(old);

    // branch to DeoptBlockTerm if the condition is false
    swap_successors(check_bi);
    set_name(get_successor(check_bi, 0), "guarded");
    set_name(get_successor(check_bi, 1), "deopt");
    mi := md_kind_id("make.implicit");
    mmd := get_metadata(guard, mi);
    if mmd != NONE set_metadata(check_bi, mi, mmd);
    set_branch_weights(check_bi, u32.[mge_predicate_pass_branch_weight, 1]);

    // IRBuilder<> B(DeoptBlockTerm): the debug location of the unreachable
    dl := get_metadata(deopt_term, 0);
    deopt_call := create_call_fn_bundle(deopt_fn, args, "deopt", deopt_inputs, true);
    insert_at_position(deopt_call, then_bb, deopt_term, false);
    if dl != NONE set_metadata(deopt_call, 0, dl);
    ret: Value_Id;
    if func_ret(glob(deopt_fn).value_type) == ir.t_void {
        ret = new_inst(.RET, ir.t_void, 0);
    } else {
        set_name(deopt_call, "deoptcall");
        ret = new_inst(.RET, ir.t_void, 1);
        set_op(ret, 0, deopt_call);
    }
    insert_at_position(ret, then_bb, deopt_term, false);
    if dl != NONE set_metadata(ret, 0, dl);
    inst(deopt_call).cc = inst(guard).cc;
    erase_inst(deopt_term);

    if use_wc {
        // IRBuilder<> B(CheckBI)
        bdl := get_metadata(check_bi, 0);
        wc_fn := get_or_insert_intrinsic_declaration(IID_EXPERIMENTAL_WIDENABLE_CONDITION);
        wc := create_call_fn_bundle(wc_fn, .[], "", .[]);
        insert_at_position(wc, check_bb, check_bi, false);
        set_name(wc, "widenable_cond");
        if bdl != NONE set_metadata(wc, 0, bdl);
        a := create_binop(.AND, op(check_bi, 0), wc);
        insert_at_position(a, check_bb, check_bi, false);
        set_name(a, "exiplicit_guard_cond");
        if bdl != NONE set_metadata(a, 0, bdl);
        set_op(check_bi, 0, a);
    }
}

// explicifyGuards + MakeGuardsExplicitPass::run
make_guards_explicit_run :: (f: Value_Id) -> Preserved {
    guard_decl := intrinsic_declaration_if_exists(IID_EXPERIMENTAL_GUARD);
    if guard_decl == NONE || !has_uses(guard_decl) return PRESERVE_ALL;
    guards: [..] Value_Id; guards.allocator = temp;
    for i: fn_insts(f) if is_inst(i) && inst_op(i) == .CALL && call_iid(i) == IID_EXPERIMENTAL_GUARD array_add(*guards, i);
    if guards.count == 0 return PRESERVE_ALL;
    deopt_fn := get_or_insert_intrinsic_declaration(IID_EXPERIMENTAL_DEOPTIMIZE, .[func_ret(glob(f).value_type)]);
    glob(deopt_fn).cc = glob(guard_decl).cc;
    for g: guards {
        make_guard_control_flow_explicit(deopt_fn, g, true);
        erase_inst(g);
    }
    return PRESERVE_NONE;
}
// Intrinsic::getDeclarationIfExists(M, ID) for a non-overloaded intrinsic
intrinsic_declaration_if_exists :: (id: Intrinsic_Id) -> Value_Id {
    for g: ir.m_functions if glob(g).intrinsic && fn_iid(g) == id return g;
    return NONE;
}
