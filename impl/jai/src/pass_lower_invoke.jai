// LowerInvoke (`lower-invoke`): port of llvm/lib/Transforms/Utils/LowerInvoke.cpp (runImpl).

lower_invoke_run :: (f: Value_Id) -> Preserved {
    changed := false;
    for bb: fn_blocks(f) {
        ii := block_terminator(bb);
        if ii == NONE || inst_op(ii) != .INVOKE continue;
        c := create_call_matching_invoke(ii);
        inst_insert_before_adopt(c, ii);
        take_name(c, ii);
        rauw_with_metadata(ii, c);
        br := create_br(invoke_normal_dest(ii));   // UncondBrInst::Create(Normal, II): no debug location
        inst_insert_before_adopt(br, ii);
        block_remove_predecessor(invoke_unwind_dest(ii), bb);
        erase_terminator(ii);
        changed = true;
    }
    if changed return .{};   // PreservedAnalyses::none()
    return PRESERVE_ALL;
}
