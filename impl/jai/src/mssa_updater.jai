// MemorySSAUpdater: port of llvm/lib/Analysis/MemorySSAUpdater.cpp (in progress; unported entry points fail loudly).

Mssa_Updater :: struct {
    mssa: *Memory_SSA;
}

mssau_wire_old_predecessors_to_new_immediate_predecessor :: (u: *Mssa_Updater, old: Value_Id, new: Value_Id, preds: [] Value_Id, identical_edges := false) {
    fatal("MemorySSAUpdater::wireOldPredecessorsToNewImmediatePredecessor is not implemented yet");
}
mssau_move_all_after_splice_blocks :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id, start: Value_Id) {
    fatal("MemorySSAUpdater::moveAllAfterSpliceBlocks is not implemented yet");
}
mssau_change_to_unreachable :: (u: *Mssa_Updater, i: Value_Id) {
    fatal("MemorySSAUpdater::changeToUnreachable is not implemented yet");
}
mssau_update_phis_when_inserting_unique_backedge_block :: (u: *Mssa_Updater, header: Value_Id, preheader: Value_Id, be: Value_Id) {
    fatal("MemorySSAUpdater::updatePhisWhenInsertingUniqueBackedgeBlock is not implemented yet");
}
